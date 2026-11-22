import XCTest
import ConfigStore
import EspansoCLI
import SnippetModel
@testable import AbbrioUI

private struct NoRunner: CommandRunner {
    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        throw CommandError.launchFailed("not available in tests")
    }
}

private let personalFile = """
# Personal
matches:
  - trigger: addr
    replace: 1 Harbour Street
  # phone
  - trigger: phone
    replace: "555 0100"
    word: true
  - regex: "n(?P<d>\\\\d)"
    replace: "{{d}}"

"""

@MainActor
final class AppModelSetInfoTests: XCTestCase {
    private var root: URL!
    private var trash: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-tests-" + UUID().uuidString)
        root = base.appendingPathComponent("config-folder")
        trash = base.appendingPathComponent("trash")
        for folder in ["match/packages/demo", "config", "../trash"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try write("config/default.yml", "toggle_key: OFF\ninject_delay: 5\n")
        try write("match/personal.yml", personalFile)
        try write("match/work.yml", "matches:\n  - trigger: \";sig\"\n    replace: Regards\n  - trigger: \";btw\"\n    replace: by the way\n")
        try write("match/_mail.yml", "matches:\n  - trigger: \";re\"\n    replace: Reply\n")
        try write("match/packages/demo/package.yml", "matches:\n  - trigger: \":smile\"\n    replace: \"🙂\"\n")
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

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    private func makeModel(ownBundleID: String? = nil) async -> AppModel {
        let trash = trash!
        let model = AppModel(
            environment: AppEnvironment(configFolderOverride: root, fallbackConfigFolders: []),
            runner: NoRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in false }),
            discard: { url in
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            },
            ownBundleID: ownBundleID
        )
        model.autosaveDelayOverride = .seconds(3600)
        await model.load()
        return model
    }

    private func select(_ trigger: String, in set: String, _ model: AppModel) {
        model.selectedSetID = set
        model.selectedSnippetID = self.set(set, model).snippets.first { $0.triggers.contains(trigger) }?.id
    }

    private func set(_ id: String, _ model: AppModel) -> SnippetSet {
        model.sets.first { $0.id == id }!
    }

    // MARK: Regular expression sets

    func testANewRegularExpressionSetTakesRulesAndStaysOneAfterAReload() async {
        let model = await makeModel()
        XCTAssertTrue(model.createSet(named: "Money", forRegularExpressions: true))
        XCTAssertEqual(text("match/money.yml"), "matches: []\n")
        XCTAssertEqual(set("money.yml", model).kind, .regularExpressions)
        XCTAssertEqual(model.newItemTitle, "New Rule")
        // The empty file can't say what it is for; the app's notes do.
        await model.load()
        XCTAssertEqual(set("money.yml", model).kind, .regularExpressions)

        model.selectedSetID = "money.yml"
        model.newItem()
        XCTAssertEqual(model.draft?.isRegex, true)
        model.updateDraft { $0.abbreviation = #":(?P<amount>\d+)usd"# }
        model.setBody("{{amount}} dollars")
        XCTAssertTrue(model.commitDraft())
        XCTAssertEqual(text("match/money.yml"), "matches:\n  - regex: \":(?P<amount>\\\\d+)usd\"\n    replace: \"{{amount}} dollars\"\n")
        XCTAssertEqual(model.regexGroupNames, ["amount"])

        model.regexSample = "cost :12usd"
        guard case .match(let match) = model.regexTestOutcome else { return XCTFail("\(model.regexTestOutcome)") }
        XCTAssertEqual(match.output, "12 dollars")
        await model.load()
        XCTAssertEqual(set("money.yml", model).kind, .regularExpressions)
        XCTAssertEqual(set("personal.yml", model).kind, .abbreviations)
    }

    func testNumberedGroupsAreConvertedInOneSave() async {
        try? write("match/rules.yml", "matches:\n  - regex: \"=(\\\\d+)=\"\n    replace: \"<$1>\"\n  - trigger: keep\n    replace: me\n")
        let model = await makeModel()
        model.selectedSetID = "rules.yml"
        model.selectedSnippetID = set("rules.yml", model).snippets.first?.id
        XCTAssertEqual(model.regexConversion?.pattern, #"=(?P<group1>\d+)="#)
        model.applyRegexConversion()
        XCTAssertEqual(text("match/rules.yml"), "matches:\n  - regex: \"=(?P<group1>\\\\d+)=\"\n    replace: \"<{{group1}}>\"\n  - trigger: keep\n    replace: me\n")
        XCTAssertNil(model.regexConversion)
        XCTAssertEqual(model.regexGroupNames, ["group1"])
    }

    func testTheMatchLengthLimitFollowsTheSetting() async throws {
        let model = await makeModel()
        XCTAssertEqual(model.regexBufferLimit, 30)
        try write("config/default.yml", "max_regex_buffer_size: 50\n")
        await model.load()
        XCTAssertEqual(model.regexBufferLimit, 50)
    }

    // MARK: Import and export

    func testAListIsImportedAsANewSetAndExportedAgain() async throws {
        let model = await makeModel()
        let file = root.appendingPathComponent("office phrases.tsv")
        try "Abbreviation\tExpansion\tDescription\n;sig\tBest regards, Robin\tSign-off\n;adr\t1 Main St\t\n\tno abbreviation\t\n".write(to: file, atomically: true, encoding: .utf8)
        model.beginImport(from: file)
        let pending = try XCTUnwrap(model.pendingImport)
        XCTAssertEqual(pending.suggestedName, "Office phrases")
        let source = SnippetImport(text: pending.text)
        XCTAssertEqual(source.delimiter, .tab)
        XCTAssertEqual(source.skippedCount, 1)

        XCTAssertTrue(model.importSet(named: "Office Phrases", from: source))
        XCTAssertNil(model.pendingImport)
        XCTAssertEqual(model.selectedSetID, "office-phrases.yml")
        XCTAssertEqual(text("match/office-phrases.yml"), "matches:\n  - trigger: \";sig\"\n    replace: Best regards, Robin\n    label: Sign-off\n  - trigger: \";adr\"\n    replace: 1 Main St\n")

        let list = root.appendingPathComponent("out.csv")
        let export = try XCTUnwrap(model.exportList(of: "office-phrases.yml", to: list))
        XCTAssertEqual(export.rowCount, 2)
        XCTAssertEqual(
            try String(contentsOf: list, encoding: .utf8),
            "abbreviation,expansion,description\r\n;sig,\"Best regards, Robin\",Sign-off\r\n;adr,1 Main St,\r\n"
        )
        XCTAssertNil(model.alertMessage)
    }

    func testASetIsExportedAsAPackageFolderWithoutChangingIt() async throws {
        let model = await makeModel()
        let before = text("match/personal.yml")
        var manifest = model.suggestedManifest(for: "personal.yml")
        XCTAssertEqual(manifest.name, "personal")
        XCTAssertEqual(manifest.title, "Personal")
        manifest.author = "Robin Example"
        let parent = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try XCTUnwrap(model.exportPackage(of: "personal.yml", manifest: manifest, to: parent))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("package.yml"), encoding: .utf8), before)
        XCTAssertEqual(text("match/personal.yml"), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("_manifest.yml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
        XCTAssertTrue(model.canExportAsPackage("personal.yml"))
        XCTAssertFalse(model.canExportAsPackage("nothing.yml"))
    }

    // MARK: Abbrio's own windows

    func testExpansionIsSwitchedOffInTheAppsOwnWindowsOnce() async throws {
        let path = "config/org.example.editor.yml"
        let written = "# \(path), written by Abbrio\nfilter_class: \"^org\\\\.example\\\\.editor$\"\nenable: false\n"
        let model = await makeModel(ownBundleID: "org.example.editor")
        XCTAssertEqual(text(path), written)
        XCTAssertFalse(model.expandsInOwnWindows)

        // Switching expansions on keeps the file, so loading again does not switch them off.
        XCTAssertTrue(model.setExpandsInOwnWindows(true))
        XCTAssertEqual(text(path), "# \(path), written by Abbrio\nfilter_class: \"^org\\\\.example\\\\.editor$\"\n")
        await model.load()
        XCTAssertTrue(model.expandsInOwnWindows)
        XCTAssertFalse(exists("config/org.example.editor-2.yml"))

        XCTAssertTrue(model.setExpandsInOwnWindows(false))
        XCTAssertEqual(text(path), written)
    }

    func testNothingIsWrittenForTheAppsOwnWindowsWithoutABundleIdentifier() async {
        let before = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("config").path).sorted()
        let model = await makeModel()
        XCTAssertNil(model.ownAppConfig)
        XCTAssertTrue(model.expandsInOwnWindows)
        let after = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("config").path).sorted()
        XCTAssertEqual(before, after)
    }

    // MARK: Prefix and suffix

    func testPrefixRewritesEveryTriggerInOneSaveAndCanBeUndone() async {
        let model = await makeModel()
        var info = set("personal.yml", model).info
        info.prefix = ","
        let preview = model.affixPreview(for: "personal.yml", prefix: ",", suffix: "")
        XCTAssertEqual(preview.examples, [",addr", ",phone"])
        XCTAssertEqual(preview.count, 2)
        XCTAssertFalse(preview.canAdopt)
        XCTAssertTrue(preview.blockedItems.isEmpty)

        XCTAssertNil(model.applySetInfo(info, name: "Personal", to: "personal.yml"))
        XCTAssertEqual(text("match/personal.yml"), personalFile
            .replacingOccurrences(of: "trigger: addr", with: "trigger: \",addr\"")
            .replacingOccurrences(of: "trigger: phone", with: "trigger: \",phone\""))
        XCTAssertEqual(set("personal.yml", model).info.prefix, ",")
        // One backup for the one save.
        XCTAssertEqual(ConfigWriter(root: root).backups(of: "match/personal.yml").count, 1)

        // The form shows the bare abbreviation with the prefix beside it.
        select(",addr", in: "personal.yml", model)
        XCTAssertEqual(model.triggerForm?.abbreviation, "addr")
        XCTAssertEqual(model.editingAffixes.prefix, ",")
        model.updateTriggers { $0.abbreviation = "home" }
        XCTAssertTrue(model.commitDraft())
        XCTAssertTrue(text("match/personal.yml").contains("trigger: \",home\""))

        model.undo()
        model.undo()
        XCTAssertEqual(text("match/personal.yml"), personalFile)
        XCTAssertEqual(set("personal.yml", model).info.prefix, "")
        model.redo()
        XCTAssertEqual(set("personal.yml", model).info.prefix, ",")
        XCTAssertTrue(text("match/personal.yml").contains("trigger: \",addr\""))
    }

    func testAPrefixTheTriggersAlreadyHaveCanBeAdopted() async {
        let model = await makeModel()
        let before = text("match/work.yml")
        let preview = model.affixPreview(for: "work.yml", prefix: ";", suffix: "")
        XCTAssertTrue(preview.canAdopt)

        var info = set("work.yml", model).info
        info.prefix = ";"
        XCTAssertNil(model.applySetInfo(info, name: "Work", to: "work.yml", adoptingAffixes: true))
        XCTAssertEqual(text("match/work.yml"), before)
        select(";sig", in: "work.yml", model)
        XCTAssertEqual(model.triggerForm?.abbreviation, "sig")

        // Adding it again doubles it, which is what was asked for.
        info.prefix = ""
        XCTAssertNil(model.applySetInfo(info, name: "Work", to: "work.yml", adoptingAffixes: true))
        info.prefix = ";"
        XCTAssertNil(model.applySetInfo(info, name: "Work", to: "work.yml", adoptingAffixes: false))
        XCTAssertTrue(text("match/work.yml").contains("trigger: \";;sig\""))
    }

    func testAnItemTheFormCannotRewriteBlocksThePrefix() async throws {
        try write("match/work.yml", "matches:\n  - trigger: a\n    replace: b\n  - { trigger: flow, replace: c }\n")
        let model = await makeModel()
        XCTAssertEqual(model.affixPreview(for: "work.yml", prefix: ";", suffix: "").blockedItems, ["flow"])
        var info = SetInfo()
        info.prefix = ";"
        let before = text("match/work.yml")
        XCTAssertNotNil(model.applySetInfo(info, name: "Work", to: "work.yml"))
        XCTAssertEqual(text("match/work.yml"), before)
        XCTAssertEqual(set("work.yml", model).info.prefix, "")
    }

    func testOtherSetInfoFieldsLiveOnlyInTheSidecar() async {
        let model = await makeModel()
        let before = text("match/work.yml")
        var info = SetInfo(defaultCase: .affectsExpansion, defaultExpand: .wordBreak, countAs: .corrections, searchExpansions: false, notes: "Office")
        XCTAssertNil(model.applySetInfo(info, name: "Day Job", to: "work.yml"))
        XCTAssertEqual(text("match/work.yml"), before)
        XCTAssertTrue(exists("match/work.yml"))
        info.name = "Day Job"
        XCTAssertEqual(set("work.yml", model).info, info)
        XCTAssertEqual(set("work.yml", model).name, "Day Job")

        // New items start with the set's defaults.
        model.newItem(in: "work.yml")
        XCTAssertEqual(model.draft?.options.propagateCase, true)
        XCTAssertEqual(model.draft?.options.word, true)

        // A fresh model reads it all back.
        let again = await makeModel()
        XCTAssertEqual(set("work.yml", again).info, info)
    }

    // MARK: Names and files

    func testRenameKeepsTheFileUnlessAsked() async {
        let model = await makeModel()
        XCTAssertTrue(model.renameWouldChangeFile("work.yml", to: "Office"))
        XCTAssertTrue(model.renameSet("work.yml", to: "Office", renamingFile: false))
        XCTAssertTrue(exists("match/work.yml"))
        XCTAssertEqual(set("work.yml", model).name, "Office")

        XCTAssertTrue(model.renameSet("work.yml", to: "Office", renamingFile: true))
        XCTAssertTrue(exists("match/office.yml"))
        XCTAssertFalse(exists("match/work.yml"))
        XCTAssertEqual(set("office.yml", model).name, "Office")
        XCTAssertNil(model.sidecar.sets["work.yml"])
    }

    func testNotesFollowASetThroughSwitchDuplicateAndDelete() async {
        let model = await makeModel()
        XCTAssertNil(model.applySetInfo(SetInfo(notes: "n"), name: "Work", to: "work.yml"))
        XCTAssertTrue(model.setEnabled(false, for: "work.yml"))
        XCTAssertEqual(set("_work.yml", model).info.notes, "n")

        XCTAssertTrue(model.duplicateSet("_work.yml"))
        XCTAssertEqual(model.selectedSetID, "_work-copy.yml")
        XCTAssertEqual(model.selectedSet?.name, "Work copy")
        XCTAssertEqual(model.selectedSet?.info.notes, "n")
        XCTAssertEqual(text("match/_work-copy.yml"), text("match/_work.yml"))

        XCTAssertTrue(model.deleteSet("_work.yml"))
        XCTAssertNil(model.sidecar.sets["_work.yml"])
    }

    func testSetsCanBeArranged() async {
        let model = await makeModel()
        XCTAssertEqual(model.sets(ofKind: .abbreviations).map(\.id), ["_mail.yml", "personal.yml", "work.yml"])
        model.moveSets(ofKind: .abbreviations, fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(model.sets(ofKind: .abbreviations).map(\.id), ["work.yml", "_mail.yml", "personal.yml"])
        let again = await makeModel()
        XCTAssertEqual(again.sets(ofKind: .abbreviations).map(\.id), ["work.yml", "_mail.yml", "personal.yml"])
    }

    // MARK: Case does not matter

    func testCaseDoesNotMatterWritesThreeTriggersAndShowsOne() async {
        let model = await makeModel()
        select(";btw", in: "work.yml", model)
        XCTAssertEqual(model.caseMode, .mustMatch)
        model.setCaseMode(.insensitive)
        XCTAssertTrue(text("match/work.yml").contains("  - triggers: [\";btw\", \";Btw\", \";BTW\"]\n    replace: by the way\n"))
        XCTAssertEqual(model.caseMode, .insensitive)
        XCTAssertEqual(model.triggerForm?.abbreviation, ";btw")
        XCTAssertEqual(model.triggerForm?.aliases, [])

        // After a restart the three triggers still show as one abbreviation.
        let again = await makeModel()
        select(";btw", in: "work.yml", again)
        XCTAssertEqual(again.caseMode, .insensitive)
        XCTAssertEqual(again.triggerForm?.aliases, [])

        // Renaming keeps the mode and writes the new variants.
        again.updateTriggers { $0.abbreviation = ";fyi" }
        XCTAssertTrue(again.commitDraft())
        XCTAssertTrue(text("match/work.yml").contains("triggers: [\";fyi\", \";Fyi\", \";FYI\"]"))
        XCTAssertTrue(again.sidecar.isCaseInsensitive(";fyi", in: "work.yml"))
        XCTAssertFalse(again.sidecar.isCaseInsensitive(";btw", in: "work.yml"))

        // The other choices undo it.
        again.setCaseMode(.affectsExpansion)
        XCTAssertTrue(text("match/work.yml").contains("  - trigger: \";fyi\"\n    replace: by the way\n    propagate_case: true\n"))
        XCTAssertEqual(again.caseMode, .affectsExpansion)
        again.setCaseMode(.mustMatch)
        XCTAssertFalse(text("match/work.yml").contains("propagate_case"))
        XCTAssertFalse(again.sidecar.isCaseInsensitive(";fyi", in: "work.yml"))
    }

    func testWithoutTheSidecarTheVariantsShowAsAliases() async throws {
        try write("match/work.yml", "matches:\n  - triggers: [btw, Btw, BTW]\n    replace: by the way\n")
        let model = await makeModel()
        select("btw", in: "work.yml", model)
        XCTAssertEqual(model.caseMode, .mustMatch)
        XCTAssertEqual(model.triggerForm?.aliases, ["Btw", "BTW"])
    }

    func testCaseModeWithAPrefixKeepsThePrefixAsWritten() async {
        let model = await makeModel()
        var info = SetInfo()
        info.prefix = ";"
        XCTAssertNil(model.applySetInfo(info, name: "Work", to: "work.yml", adoptingAffixes: true))
        select(";btw", in: "work.yml", model)
        model.setCaseMode(.insensitive)
        XCTAssertTrue(text("match/work.yml").contains("triggers: [\";btw\", \";Btw\", \";BTW\"]"))
        XCTAssertEqual(model.triggerForm?.abbreviation, "btw")
        XCTAssertTrue(model.sidecar.isCaseInsensitive("btw", in: "work.yml"))
    }

    // MARK: Moving items

    func testMoveAndCopyBetweenSets() async {
        let model = await makeModel()
        select("phone", in: "personal.yml", model)
        let id = model.selectedSnippetID!
        XCTAssertTrue(model.moveItems([id], toSet: "work.yml", copying: false))
        XCTAssertFalse(text("match/personal.yml").contains("phone"))
        XCTAssertTrue(text("match/work.yml").hasSuffix("  # phone\n  - trigger: phone\n    replace: \"555 0100\"\n    word: true\n"))
        XCTAssertEqual(set("work.yml", model).snippets.count, 3)

        model.undo()
        XCTAssertEqual(text("match/personal.yml"), personalFile)
        XCTAssertEqual(set("work.yml", model).snippets.count, 2)

        select("addr", in: "personal.yml", model)
        XCTAssertTrue(model.moveItems([model.selectedSnippetID!], toSet: "work.yml", copying: true))
        XCTAssertEqual(text("match/personal.yml"), personalFile)
        XCTAssertEqual(set("work.yml", model).snippets.last?.abbreviation, "addr")

        // Nothing goes into a package, and dropping on the item's own set does nothing.
        XCTAssertFalse(model.moveItems([model.selectedSnippetID!], toSet: "packages/demo", copying: true))
        XCTAssertFalse(model.moveItems([Snippet.ID(file: "match/work.yml", index: 0)], toSet: "work.yml", copying: false))
    }

    // MARK: Apps

    func testAppGridCompilesToConfigAndSurvivesARestart() async {
        let model = await makeModel()
        XCTAssertTrue(model.appConfigs.isEmpty)
        let path = model.addApp(bundleID: "com.apple.mail", bundlePath: "/System/Applications/Mail.app")
        XCTAssertEqual(path, "config/com.apple.mail.yml")
        XCTAssertEqual(model.appConfigs.map(\.path), ["config/com.apple.mail.yml"])
        XCTAssertEqual(model.bundleID(of: model.appConfigs[0]), "com.apple.mail")
        XCTAssertEqual(model.changeCount(inApp: path!), 0)

        let mail = set("_mail.yml", model), work = set("work.yml", model), demo = set("packages/demo", model)
        XCTAssertEqual(model.state(of: mail, inApp: path!), .same(isOn: false))
        XCTAssertTrue(model.setOn(true, mail, inApp: path!))
        XCTAssertTrue(model.setOn(false, work, inApp: path!))
        XCTAssertTrue(model.setOn(false, demo, inApp: path!))
        XCTAssertEqual(text(path!), """
        # config/com.apple.mail.yml, written by Abbrio
        filter_class: "^com\\\\.apple\\\\.mail$"
        extra_includes:
          - "../match/_mail.yml"
        extra_excludes:
          - "../match/work.yml"
          - "../match/packages/demo/*"

        """)
        XCTAssertEqual(model.changeCount(inApp: path!), 3)

        // A new model has only the files to go by.
        let again = await makeModel()
        XCTAssertEqual(again.state(of: set("_mail.yml", again), inApp: path!), .onHere)
        XCTAssertEqual(again.state(of: set("work.yml", again), inApp: path!), .offHere)
        XCTAssertEqual(again.state(of: set("packages/demo", again), inApp: path!), .offHere)
        XCTAssertEqual(again.state(of: set("personal.yml", again), inApp: path!), .same(isOn: true))

        // Adding the same app again uses the file that is there.
        XCTAssertEqual(again.addApp(bundleID: "com.apple.mail", bundlePath: nil), path)
        XCTAssertEqual(again.appConfigs.count, 1)
    }

    func testGlobalSwitchKeepsTheAppsChoice() async {
        let model = await makeModel()
        let path = model.addApp(bundleID: "com.apple.mail", bundlePath: nil)!
        XCTAssertTrue(model.setOn(false, set("work.yml", model), inApp: path))
        // Off everywhere: the file is renamed and the app's line follows it.
        XCTAssertTrue(model.setEnabled(false, for: "work.yml"))
        XCTAssertTrue(text(path).contains("../match/_work.yml"))
        XCTAssertEqual(model.state(of: set("_work.yml", model), inApp: path), .same(isOn: false))
        // On everywhere again: still off in Mail.
        XCTAssertTrue(model.setEnabled(true, for: "_work.yml"))
        XCTAssertEqual(model.state(of: set("work.yml", model), inApp: path), .offHere)
    }

    func testTurnAllOffOptionsOverlapsAndRemoval() async throws {
        try write("config/a-mail.yml", "filter_class: apple\\.mail\n")
        try write("config/zz.yml", "filter_title: Inbox\n")
        let model = await makeModel()
        // A hand-written file already matches Mail, so it is used instead of a new one.
        XCTAssertEqual(model.addApp(bundleID: "com.apple.mail", bundlePath: nil), "config/a-mail.yml")
        XCTAssertFalse(exists("config/com.apple.mail.yml"))
        XCTAssertNil(model.overlaps(forApp: "config/a-mail.yml", bundlePath: nil))

        let path = model.addApp(bundleID: "com.vscodium", bundlePath: nil)!
        XCTAssertEqual(model.overlaps(forApp: path, bundlePath: nil), [
            AppOverlap(path: "config/zz.yml", isCertain: false, wins: false),
        ])
        try write("config/b.yml", "filter_class: vscodium\n")
        await model.load()
        XCTAssertEqual(model.overlaps(forApp: path, bundlePath: nil)?.first, AppOverlap(path: "config/b.yml", isCertain: true, wins: true))

        XCTAssertTrue(model.setAllOff(true, inApp: path))
        XCTAssertTrue(model.isAllOff(inApp: path))
        XCTAssertTrue(text(path).hasSuffix("enable: false\n"))
        XCTAssertTrue(model.setAllOff(false, inApp: path))
        XCTAssertFalse(text(path).contains("enable"))

        XCTAssertEqual(model.inheritedOption("inject_delay"), "5")
        XCTAssertTrue(model.setOption("inject_delay", .integer(30), inApp: path))
        XCTAssertTrue(model.setOption("backend", .string("Clipboard"), inApp: path))
        XCTAssertTrue(text(path).hasSuffix("inject_delay: 30\nbackend: \"Clipboard\"\n"))
        XCTAssertEqual(model.appConfig(path)?.values["backend"], "Clipboard")
        XCTAssertEqual(model.changeCount(inApp: path), 2)
        XCTAssertTrue(model.setOption("inject_delay", nil, inApp: path))
        XCTAssertFalse(text(path).contains("inject_delay"))

        XCTAssertTrue(model.removeApp(path))
        XCTAssertFalse(exists(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("com.vscodium.yml").path))
        XCTAssertEqual(model.appConfigs.map(\.path), ["config/a-mail.yml", "config/b.yml", "config/zz.yml"])
    }
}
