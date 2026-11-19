import XCTest
import SnippetModel
@testable import ConfigStore

final class TriggerRewriteTests: XCTestCase {
    private let path = "match/commented.yml"

    private func fixture(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.resourceURL)
        return try Data(contentsOf: base.appendingPathComponent("Fixtures/golden").appendingPathComponent(name))
    }

    private func snippets(_ data: Data, path: String = "match/commented.yml") throws -> [Snippet] {
        try MatchFileParser.parse(String(decoding: data, as: UTF8.self), path: path).snippets
    }

    /// New triggers for every match, after the set's prefix changed.
    private func reaffixed(_ data: Data, from old: String, to new: String) throws -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        for snippet in try snippets(data) where !snippet.isRegex {
            result[snippet.id.index] = snippet.triggers.map {
                TriggerForm.reaffix($0, from: (old, ""), to: (new, ""))
            }
        }
        return result
    }

    func testChangingThePrefixRewritesOnlyTheTriggerLines() throws {
        let before = try fixture("commented.yml")
        let after = try MatchFileEditor.replaceTriggers(try reaffixed(before, from: ";", to: ","), in: before, path: path)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), String(decoding: try fixture("commented.comma-prefix.yml"), as: UTF8.self))

        // And back again gives the original file, byte for byte.
        let back = try MatchFileEditor.replaceTriggers(try reaffixed(after, from: ",", to: ";"), in: after, path: path)
        XCTAssertEqual(back, before)
    }

    func testNothingToChangeLeavesTheBytesAlone() throws {
        let before = try fixture("commented.yml")
        XCTAssertEqual(try MatchFileEditor.replaceTriggers([:], in: before, path: path), before)
        XCTAssertEqual(try MatchFileEditor.replaceTriggers(try reaffixed(before, from: ";", to: ";"), in: before, path: path), before)
    }

    func testWindowsLineEndingsSurviveAPrefixChange() throws {
        let unix = String(decoding: try fixture("commented.yml"), as: UTF8.self)
        let before = Data(unix.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let after = try MatchFileEditor.replaceTriggers(try reaffixed(before, from: ";", to: ","), in: before, path: path)
        let expected = String(decoding: try fixture("commented.comma-prefix.yml"), as: UTF8.self)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), expected.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testAnItemTheFormCannotChangeStopsTheWholeRewrite() throws {
        let before = Data("""
        matches:
          - trigger: one
            replace: 1
          - { trigger: two, replace: 2 }
          - regex: "t(?P<n>\\\\d)"
            replace: "{{n}}"

        """.utf8)
        XCTAssertThrowsError(try MatchFileEditor.replaceTriggers([0: [";one"], 1: [";two"]], in: before, path: path)) { error in
            guard case .notEditable(let message) = error as? EditError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("two"))
            XCTAssertFalse(message.contains("one,"))
        }
        // Without the flow-style item the others can be rewritten, and the regex rule is not touched.
        let after = try MatchFileEditor.replaceTriggers([0: [";one"]], in: before, path: path)
        XCTAssertEqual(try snippets(after).map(\.abbreviation), [";one", "two", "t(?P<n>\\d)"])
    }

    func testEmptyTriggersAreRefused() throws {
        let before = Data("matches:\n  - trigger: a\n    replace: b\n".utf8)
        XCTAssertThrowsError(try MatchFileEditor.replaceTriggers([0: [""]], in: before, path: path))
    }

    func testCaseVariantsAreWrittenAsAList() throws {
        let before = try fixture("commented.yml")
        let form = TriggerForm(abbreviation: "hello", isCaseInsensitive: true)
        let after = try MatchFileEditor.replaceTriggers([0: form.triggers(prefix: ";", suffix: "")], in: before, path: path)
        let lines = String(decoding: after, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(lines[13], "  - triggers: [\";hello\", \";Hello\", \";HELLO\"]")
        // Every other line is as it was.
        var original = String(decoding: before, as: UTF8.self).components(separatedBy: "\n")
        original[13] = lines[13]
        XCTAssertEqual(lines, original)
    }

    // MARK: Copy between files

    func testCopyBringsTheCommentAndFitsTheIndentation() throws {
        let source = try fixture("commented.yml")
        let target = Data("# Other set\nmatches:\n- trigger: x\n  replace: y\n".utf8)
        let result = try MatchFileEditor.copy(matchAt: 0, from: source, path: path, to: target, path: "match/other.yml")
        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), """
        # Other set
        matches:
        - trigger: x
          replace: y
        # Opening line for a first reply.
        - trigger: ";hello"
          replace: "Hello, and thanks for getting in touch."
          label: First reply   # shown in search

        """)
    }

    func testCopyOfABlockScalarIntoAnEmptyFile() throws {
        let source = try fixture("commented.yml")
        let result = try MatchFileEditor.copy(
            matchAt: 1, from: source, path: path, to: Data("matches: []\n".utf8), path: "match/other.yml"
        )
        let copied = try XCTUnwrap(try snippets(result.data, path: "match/other.yml").first)
        let original = try snippets(source)[1]
        XCTAssertEqual(copied.expansion, original.expansion)
        XCTAssertEqual(copied.source, original.source)
        XCTAssertTrue(String(decoding: result.data, as: UTF8.self).hasPrefix("matches:\n  - trigger: \";wait\"\n"))
    }

    func testCopyRefusesAnAlias() throws {
        let source = Data("""
        matches:
          - &base
            trigger: a
            replace: b
          - *base

        """.utf8)
        XCTAssertThrowsError(try MatchFileEditor.copy(
            matchAt: 1, from: source, path: path, to: Data("matches: []\n".utf8), path: "match/other.yml"
        ))
    }

    // MARK: Global variables

    func testGlobalVariablesAreReadForDisplay() throws {
        let parsed = try MatchFileParser.parse(String(decoding: try fixture("commented.yml"), as: UTF8.self), path: path)
        XCTAssertEqual(parsed.globalVariables, [GlobalVariable(name: "desk", type: "echo", value: "Harbour Street Support")])
    }
}

final class SidecarTests: XCTestCase {
    func testRoundTripAndFileNames() throws {
        let config = try TemporaryConfig(files: ["match/work.yml": "matches: []\n"])
        let store = SidecarStore(root: config.root)
        XCTAssertEqual(store.load(), Sidecar())
        XCTAssertNil(store.data())

        var sidecar = Sidecar()
        sidecar.setInfo(SetInfo(name: "Work", order: 2, prefix: ";", defaultCase: .insensitive, notes: "Office"), for: "work.yml")
        sidecar.setCaseInsensitive(true, for: "btw", in: "work.yml")
        try store.save(sidecar)

        XCTAssertEqual(store.load(), sidecar)
        // Only a .json file appears: nothing Espanso reloads for, and no temporary file is left.
        XCTAssertEqual(config.listing(), [".abbrio/metadata.json", "match/work.yml"])

        let loaded = ConfigLoader(root: config.root).load()
        XCTAssertEqual(loaded.sets.first?.name, "Work")
        XCTAssertEqual(loaded.sets.first?.info.prefix, ";")
        XCTAssertTrue(loaded.sidecar.isCaseInsensitive("btw", in: "work.yml"))
    }

    func testDefaultsAreNotStoredAndStaleOrOddContentIsTolerated() throws {
        var sidecar = Sidecar()
        sidecar.setInfo(SetInfo(), for: "a.yml")
        XCTAssertTrue(sidecar.sets.isEmpty)
        sidecar.setCaseInsensitive(true, for: "x", in: "a.yml")
        sidecar.setCaseInsensitive(false, for: "x", in: "a.yml")
        XCTAssertTrue(sidecar.matches.isEmpty)

        let odd = Data(#"{"sets":{"a.yml":{"prefix":7,"notes":"kept","future":true}},"extra":[1]}"#.utf8)
        let decoded = try JSONDecoder().decode(Sidecar.self, from: odd)
        XCTAssertEqual(decoded.info(for: "a.yml").notes, "kept")
        XCTAssertEqual(decoded.info(for: "a.yml").prefix, "")

        let config = try TemporaryConfig(files: [".abbrio/metadata.json": "not json"])
        let store = SidecarStore(root: config.root)
        XCTAssertEqual(store.load(), Sidecar())
        var new = Sidecar()
        new.setInfo(SetInfo(notes: "n"), for: "a.yml")
        try store.save(new)
        XCTAssertEqual(config.text(".abbrio/metadata.unreadable.bak"), "not json")
    }

    func testNotesFollowARenamedFile() {
        var sidecar = Sidecar()
        sidecar.setInfo(SetInfo(prefix: ";"), for: "a.yml")
        sidecar.setCaseInsensitive(true, for: "x", in: "a.yml")
        sidecar.moveSet(from: "a.yml", to: "_a.yml")
        XCTAssertEqual(sidecar.info(for: "_a.yml").prefix, ";")
        XCTAssertTrue(sidecar.isCaseInsensitive("x", in: "_a.yml"))
        XCTAssertNil(sidecar.sets["a.yml"])
        sidecar.removeSet("_a.yml")
        XCTAssertEqual(sidecar, Sidecar())
    }

    func testArrangedSetsComeFirst() throws {
        let config = try TemporaryConfig(files: [
            "match/alpha.yml": "matches: []\n", "match/beta.yml": "matches: []\n", "match/gamma.yml": "matches: []\n",
        ])
        var sidecar = Sidecar()
        sidecar.setInfo(SetInfo(order: 0), for: "gamma.yml")
        sidecar.setInfo(SetInfo(order: 1), for: "alpha.yml")
        try SidecarStore(root: config.root).save(sidecar)
        XCTAssertEqual(ConfigLoader(root: config.root).load().sets.map(\.id), ["gamma.yml", "alpha.yml", "beta.yml"])
    }

    func testDuplicateSetKeepsItsState() throws {
        let config = try TemporaryConfig(files: ["match/_mail.yml": "matches: []\n", "match/_mail-copy.yml": "x: 1\n"])
        let outcome = try SetManager(writer: ConfigWriter(root: config.root)).duplicateSet("_mail.yml")
        XCTAssertEqual(outcome.id, "_mail-copy-2.yml")
        XCTAssertEqual(config.text("match/_mail-copy-2.yml"), "matches: []\n")
    }
}

final class AppConfigTests: XCTestCase {
    private let mailFilter = "filter_class: \"^com\\\\.apple\\\\.mail$\"\n"

    private func makeConfig(_ extra: [String: String] = [:]) throws -> TemporaryConfig {
        var files = [
            "config/default.yml": "# Everything\ntoggle_key: OFF\n",
            "match/work.yml": "matches: []\n",
            "match/autocorrect.yml": "matches: []\n",
            "match/_email-signatures.yml": "matches: []\n",
            "match/packages/basic-emojis/package.yml": "matches: []\n",
        ]
        files.merge(extra) { _, new in new }
        return try TemporaryConfig(files: files)
    }

    private func editor(_ config: TemporaryConfig) -> AppConfigEditor {
        AppConfigEditor(writer: ConfigWriter(root: config.root), discard: { try FileManager.default.removeItem(at: $0) })
    }

    private func files(_ config: TemporaryConfig) -> (base: ConfigFile?, all: [ConfigFile]) {
        let all = ConfigLoader(root: config.root).load().configFiles
        return (all.first(where: \.isDefault), all)
    }

    // MARK: Filters

    func testClassPatternEscapesAndReadsBack() {
        XCTAssertEqual(AppFilter.classPattern(forBundleID: "com.apple.mail"), "^com\\.apple\\.mail$")
        XCTAssertEqual(AppFilter.bundleID(fromClassPattern: "^com\\.apple\\.mail$"), "com.apple.mail")
        XCTAssertEqual(AppFilter.bundleID(fromClassPattern: "^org.(mozilla|x)\\.app$"), nil)
        XCTAssertEqual(AppFilter.bundleID(fromClassPattern: "com\\.apple\\.mail"), nil)
        let odd = "com.example.a+b(c)"
        XCTAssertEqual(AppFilter.bundleID(fromClassPattern: AppFilter.classPattern(forBundleID: odd)), odd)
    }

    func testAddingAnAppWritesOnlyTheFilter() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        XCTAssertEqual(path, "config/com.apple.mail.yml")
        XCTAssertEqual(config.text(path), "# config/com.apple.mail.yml, written by Abbrio\n" + mailFilter)
        let file = try XCTUnwrap(files(config).all.first { $0.path == path })
        XCTAssertEqual(file.filterClass.flatMap(AppFilter.bundleID(fromClassPattern:)), "com.apple.mail")
        XCTAssertEqual(AppFilter.match(file, bundleID: "com.apple.mail", path: nil), .yes)
        XCTAssertEqual(AppFilter.match(file, bundleID: "com.apple.mailx", path: nil), .no)
        // A second file for the same app gets another name instead of replacing the first.
        XCTAssertEqual(try editor(config).addApp(bundleID: "com.apple.mail"), "config/com.apple.mail-2.yml")
    }

    func testAddingAnAppWithExpansionOffWritesTheFilterAndTheSwitch() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail", allOff: true)
        XCTAssertEqual(config.text(path), "# config/com.apple.mail.yml, written by Abbrio\n" + mailFilter + "enable: false\n")
        let file = try XCTUnwrap(files(config).all.first { $0.path == path })
        XCTAssertEqual(file.enable, false)
        // Switching it back on leaves the file as a plain add would have written it.
        try editor(config).setAllOff(false, in: path)
        XCTAssertEqual(config.text(path), "# config/com.apple.mail.yml, written by Abbrio\n" + mailFilter)
    }

    // MARK: Compile rules, one test per row of the table

    func testOnEverywhereAndOnHereWritesNothing() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        let before = config.text(path)
        try editor(config).setLoaded(true, .set("work.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), before)
    }

    func testOnEverywhereAndOffHereWritesAnExclude() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        try editor(config).setLoaded(false, .set("autocorrect.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), """
        # config/com.apple.mail.yml, written by Abbrio
        filter_class: "^com\\\\.apple\\\\.mail$"
        extra_excludes:
          - "../match/autocorrect.yml"

        """)
        // Checking it again removes the line and the key.
        try editor(config).setLoaded(true, .set("autocorrect.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), "# config/com.apple.mail.yml, written by Abbrio\n" + mailFilter)
    }

    func testOffEverywhereAndOnHereWritesAnInclude() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        try editor(config).setLoaded(true, .set("_email-signatures.yml"), in: path, base: files(config).base)
        try editor(config).setLoaded(false, .set("autocorrect.yml"), in: path, base: files(config).base)
        // The example from the design, with both lists.
        XCTAssertEqual(config.text(path), """
        # config/com.apple.mail.yml, written by Abbrio
        filter_class: "^com\\\\.apple\\\\.mail$"
        extra_includes:
          - "../match/_email-signatures.yml"
        extra_excludes:
          - "../match/autocorrect.yml"

        """)
    }

    func testOffEverywhereAndOffHereWritesNothing() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        try editor(config).setLoaded(false, .set("_email-signatures.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), "# config/com.apple.mail.yml, written by Abbrio\n" + mailFilter)
    }

    func testTurnAllOffWritesEnableFalseAndKeepsTheGrid() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        try editor(config).setLoaded(false, .set("autocorrect.yml"), in: path, base: files(config).base)
        try editor(config).setAllOff(true, in: path)
        XCTAssertEqual(config.text(path), """
        # config/com.apple.mail.yml, written by Abbrio
        filter_class: "^com\\\\.apple\\\\.mail$"
        extra_excludes:
          - "../match/autocorrect.yml"
        enable: false

        """)
        let (base, all) = files(config)
        let file = try XCTUnwrap(all.first { $0.path == path })
        XCTAssertTrue(ConfigEvaluator(base: base).isDisabled(in: file))
        XCTAssertFalse(ConfigEvaluator(base: base).isLoaded("match/autocorrect.yml", in: file))

        try editor(config).setAllOff(false, in: path)
        XCTAssertFalse(config.text(path)?.contains("enable") ?? true)
        XCTAssertTrue(config.text(path)?.contains("autocorrect.yml") ?? false)
    }

    func testPackageOffHereExcludesItsFolder() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        try editor(config).setLoaded(false, .package("basic-emojis"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), """
        # config/com.apple.mail.yml, written by Abbrio
        filter_class: "^com\\\\.apple\\\\.mail$"
        extra_excludes:
          - "../match/packages/basic-emojis/*"

        """)
        let (base, all) = files(config)
        let file = all.first { $0.path == path }
        XCTAssertFalse(ConfigEvaluator(base: base).isLoaded("match/packages/basic-emojis/package.yml", in: file))
        XCTAssertTrue(ConfigEvaluator(base: base).isLoaded("match/packages/basic-emojis/package.yml", in: nil))
    }

    // MARK: Reading the grid back

    func testTheGridIsReadBackFromTheFilesAlone() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        try editor(config).setLoaded(true, .set("_email-signatures.yml"), in: path, base: files(config).base)
        try editor(config).setLoaded(false, .set("autocorrect.yml"), in: path, base: files(config).base)

        // A fresh read of the folder, as after restarting the app.
        let (base, all) = files(config)
        let mail = all.first { $0.path == path }
        let evaluator = ConfigEvaluator(base: base)
        let ids = ["work.yml", "autocorrect.yml", "_email-signatures.yml"]
        XCTAssertEqual(ids.map { evaluator.isLoaded("match/" + $0, in: mail) }, [true, false, true])
        XCTAssertEqual(ids.map { evaluator.isLoaded("match/" + $0, in: nil) }, [true, true, false])
    }

    func testHandWrittenFileKeepsItsOtherBytes() throws {
        let original = """
        # Mail, set up by hand
        filter_class: com\\.apple\\.mail   # loose on purpose

        backend: Clipboard
        extra_excludes: ["../match/work.yml"]
        # trailing note

        """
        let config = try makeConfig(["config/mail.yml": original])
        try editor(config).setLoaded(false, .set("autocorrect.yml"), in: "config/mail.yml", base: files(config).base)
        XCTAssertEqual(config.text("config/mail.yml"), """
        # Mail, set up by hand
        filter_class: com\\.apple\\.mail   # loose on purpose

        backend: Clipboard
        extra_excludes:
          - "../match/work.yml"
          - "../match/autocorrect.yml"
        # trailing note

        """)
        try editor(config).setLoaded(true, .set("_email-signatures.yml"), in: "config/mail.yml", base: files(config).base)
        try editor(config).setOption("inject_delay", .integer(20), in: "config/mail.yml")
        try editor(config).setOption("backend", nil, in: "config/mail.yml")
        XCTAssertEqual(config.text("config/mail.yml"), """
        # Mail, set up by hand
        filter_class: com\\.apple\\.mail   # loose on purpose

        extra_excludes:
          - "../match/work.yml"
          - "../match/autocorrect.yml"
        # trailing note
        extra_includes:
          - "../match/_email-signatures.yml"
        inject_delay: 20

        """)
        // The earlier versions are in the backup folder.
        XCTAssertEqual(ConfigWriter(root: config.root).backups(of: "config/mail.yml").count, 4)
    }

    func testAGlobThatDecidesTheMatterIsReported() throws {
        let config = try makeConfig(["config/mail.yml": mailFilter + "extra_excludes:\n  - \"../match/auto*.yml\"\n"])
        let before = config.text("config/mail.yml")
        XCTAssertThrowsError(try editor(config).setLoaded(true, .set("autocorrect.yml"), in: "config/mail.yml", base: files(config).base))
        XCTAssertEqual(config.text("config/mail.yml"), before)
    }

    func testDefaultListsCountForEveryApp() throws {
        let config = try makeConfig([
            "config/default.yml": "extra_includes:\n  - \"../match/_email-signatures.yml\"\nextra_excludes:\n  - \"../match/packages/**/*\"\n",
        ])
        let evaluator = ConfigEvaluator(base: files(config).base)
        XCTAssertTrue(evaluator.isLoaded("match/_email-signatures.yml", in: nil))
        XCTAssertFalse(evaluator.isLoaded("match/packages/basic-emojis/package.yml", in: nil))
        XCTAssertTrue(evaluator.isLoaded("match/work.yml", in: nil))
        XCTAssertTrue(evaluator.isLoaded("match/team/shared.yml", in: nil))
        XCTAssertFalse(evaluator.isLoaded("match/team/_shared.yml", in: nil))
    }

    func testAnAppsListReplacesTheSameListInDefault() throws {
        let config = try makeConfig([
            "config/default.yml": "extra_includes:\n  - \"../match/_email-signatures.yml\"\nextra_excludes:\n  - \"../match/work.yml\"\n",
            "config/inherits.yml": mailFilter,
            "config/own.yml": "filter_class: notes\nextra_includes:\n  - \"../match/_other.yml\"\n",
            "config/empty.yml": "filter_class: safari\nextra_excludes: []\n",
            "match/_other.yml": "matches: []\n",
        ])
        let (base, all) = files(config)
        let evaluator = ConfigEvaluator(base: base)
        func loaded(_ set: String, _ name: String) -> Bool {
            evaluator.isLoaded("match/" + set, in: all.first { $0.path == "config/" + name })
        }
        // No list of its own: both lists come from default.yml.
        XCTAssertTrue(loaded("_email-signatures.yml", "inherits.yml"))
        XCTAssertFalse(loaded("work.yml", "inherits.yml"))
        // Its own extra_includes replaces the one in default.yml; extra_excludes is still inherited.
        XCTAssertTrue(loaded("_other.yml", "own.yml"))
        XCTAssertFalse(loaded("_email-signatures.yml", "own.yml"))
        XCTAssertFalse(loaded("work.yml", "own.yml"))
        // An empty list of its own replaces the one in default.yml too.
        XCTAssertTrue(loaded("work.yml", "empty.yml"))
        XCTAssertTrue(loaded("_email-signatures.yml", "empty.yml"))
    }

    func testANewListStartsFromTheEntriesInDefault() throws {
        let config = try makeConfig([
            "config/default.yml": "extra_includes:\n  - \"../match/_email-signatures.yml\"\nextra_excludes:\n  - \"../match/work.yml\"\n",
        ])
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        let header = "# config/com.apple.mail.yml, written by Abbrio\n" + mailFilter

        // Off here, on elsewhere: the entry from default.yml is carried along, so work.yml stays off.
        try editor(config).setLoaded(false, .set("autocorrect.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), header + "extra_excludes:\n  - \"../match/work.yml\"\n  - \"../match/autocorrect.yml\"\n")
        var (base, all) = files(config)
        var mail = all.first { $0.path == path }
        XCTAssertFalse(ConfigEvaluator(base: base).isLoaded("match/work.yml", in: mail))
        XCTAssertFalse(ConfigEvaluator(base: base).isLoaded("match/autocorrect.yml", in: mail))

        // Back on: the list equals the one in default.yml again, so the key goes.
        try editor(config).setLoaded(true, .set("autocorrect.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), header)

        // Switching on what default.yml excludes needs an empty list of its own.
        try editor(config).setLoaded(true, .set("work.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), header + "extra_excludes: []\n")
        // Switching off what default.yml includes does too.
        try editor(config).setLoaded(false, .set("_email-signatures.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), header + "extra_excludes: []\nextra_includes: []\n")
        (base, all) = files(config)
        mail = all.first { $0.path == path }
        XCTAssertTrue(ConfigEvaluator(base: base).isLoaded("match/work.yml", in: mail))
        XCTAssertFalse(ConfigEvaluator(base: base).isLoaded("match/_email-signatures.yml", in: mail))

        // And back to what all other applications have: both keys go.
        try editor(config).setLoaded(false, .set("work.yml"), in: path, base: files(config).base)
        try editor(config).setLoaded(true, .set("_email-signatures.yml"), in: path, base: files(config).base)
        XCTAssertEqual(config.text(path), header)
    }

    // MARK: Overlaps

    func testOverlappingFiltersAreDetected() throws {
        let config = try makeConfig([
            "config/a-mail.yml": "filter_class: apple\\.mail\n",
            "config/exec.yml": "filter_exec: \"/Mail\\\\.app\"\n",
            "config/title.yml": "filter_title: Inbox\n",
            "config/other.yml": "filter_class: \"^com\\\\.vscodium$\"\n",
            "config/odd.yml": "filter_class: \"(?P<x>mail)\"\n",
            "config/both.yml": "filter_class: mail\nfilter_exec: Safari\n",
        ])
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        let all = files(config).all
        func match(_ name: String, path appPath: String? = "/System/Applications/Mail.app") -> FilterMatch {
            AppFilter.match(all.first { $0.path == "config/" + name }!, bundleID: "com.apple.mail", path: appPath)
        }
        XCTAssertEqual(match("a-mail.yml"), .yes)
        XCTAssertEqual(match("exec.yml"), .yes)
        XCTAssertEqual(match("exec.yml", path: nil), .maybe)
        XCTAssertEqual(match("title.yml"), .maybe)
        XCTAssertEqual(match("other.yml"), .no)
        XCTAssertEqual(match("odd.yml"), .maybe)
        XCTAssertEqual(match("both.yml"), .no)
        XCTAssertEqual(match("default.yml"), .no)
        XCTAssertEqual(match((path as NSString).lastPathComponent), .yes)
    }

    func testRemovingAnApp() throws {
        let config = try makeConfig()
        let path = try editor(config).addApp(bundleID: "com.apple.mail")
        try editor(config).removeApp(configPath: path)
        XCTAssertFalse(config.exists(path))
    }
}
