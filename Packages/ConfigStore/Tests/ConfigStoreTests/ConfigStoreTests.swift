import XCTest
import SnippetModel
@testable import ConfigStore

private func fixtureURL(_ path: String) throws -> URL {
    let base = try XCTUnwrap(Bundle.module.resourceURL)
    return base.appendingPathComponent("Fixtures").appendingPathComponent(path)
}

final class MatchFileParserTests: XCTestCase {
    private func edgeCases() throws -> (text: String, parsed: ParsedMatchFile) {
        let text = try String(contentsOf: fixtureURL("files/edge-cases.yml"), encoding: .utf8)
        return (text, try MatchFileParser.parse(text, path: "match/edge-cases.yml"))
    }

    func testReadsEveryMatchAndSkipsTheStrayItem() throws {
        let parsed = try edgeCases().parsed
        XCTAssertEqual(
            parsed.snippets.map(\.abbreviation),
            [";one", ";block", ";flow", ";anchor", ";merged", ";unicode", ";multi"]
        )
        XCTAssertEqual(parsed.snippets.map(\.id.index), [0, 1, 2, 3, 4, 5, 7])
        XCTAssertEqual(parsed.problems.count, 1)
        XCTAssertEqual(parsed.problems.first?.severity, .skipped)
        XCTAssertEqual(parsed.problems.first?.line, 34)
        XCTAssertEqual(parsed.imports, ["_shared.yml"])
        XCTAssertEqual(parsed.globalVariableNames, ["greeting"])
    }

    func testSourceRanges() throws {
        let parsed = try edgeCases().parsed
        let ranges = parsed.snippets.map(\.sourceRange)
        XCTAssertEqual(ranges, [
            LineRange(first: 8, last: 9),
            LineRange(first: 11, last: 16),
            LineRange(first: 20, last: 20),
            LineRange(first: 22, last: 25),
            LineRange(first: 27, last: 28),
            LineRange(first: 30, last: 32),
            LineRange(first: 36, last: 39),
        ])
        XCTAssertEqual(parsed.leadingComments[0], LineRange(first: 6, last: 7))
        XCTAssertEqual(parsed.leadingComments[2], LineRange(first: 19, last: 19))
        XCTAssertNil(parsed.leadingComments[1])
    }

    func testSourceTextIsTheFileTextOfTheRange() throws {
        let (text, parsed) = try edgeCases()
        let lines = text.components(separatedBy: "\n")
        for snippet in parsed.snippets {
            let range = try XCTUnwrap(snippet.sourceRange)
            XCTAssertEqual(snippet.source, lines[(range.first - 1)...(range.last - 1)].joined(separator: "\n"))
        }
        XCTAssertEqual(parsed.snippets[2].source, "  - { trigger: \";flow\", replace: \"inline\" }")
    }

    func testValues() throws {
        let parsed = try edgeCases().parsed
        let block = parsed.snippets[1]
        XCTAssertEqual(block.expansion, .text("Line one\n\nLine three, after a blank line\n"))
        XCTAssertTrue(block.options.word)

        let unicode = parsed.snippets[5]
        XCTAssertEqual(unicode.expansion, .text("naïve café — ☕"))
        XCTAssertEqual(unicode.unknownKeys, ["custom_key"])

        let multi = parsed.snippets[6]
        XCTAssertEqual(multi.triggers, [";multi", ";many"])
        XCTAssertEqual(multi.aliases, [";many"])
    }

    func testAdvancedYAMLIsFlagged() throws {
        let parsed = try edgeCases().parsed
        let flags = Dictionary(uniqueKeysWithValues: parsed.snippets.map { ($0.abbreviation, $0.needsAdvancedYAML) })
        XCTAssertEqual(flags, [
            ";one": false,
            ";block": false,
            ";flow": true,
            ";anchor": true,
            ";merged": true,
            ";unicode": true,
            ";multi": false,
        ])
    }

    func testWindowsLineEndingsGiveTheSameRanges() throws {
        let (text, parsed) = try edgeCases()
        let windows = text.replacingOccurrences(of: "\n", with: "\r\n")
        let again = try MatchFileParser.parse(windows, path: "match/edge-cases.yml")
        XCTAssertEqual(again.snippets.map(\.sourceRange), parsed.snippets.map(\.sourceRange))
        XCTAssertEqual(again.snippets.map(\.source), parsed.snippets.map(\.source))
    }

    func testEmptyAndMinimalFiles() throws {
        XCTAssertTrue(try MatchFileParser.parse("", path: "match/a.yml").snippets.isEmpty)
        XCTAssertTrue(try MatchFileParser.parse("# only a comment\n", path: "match/a.yml").snippets.isEmpty)
        XCTAssertTrue(try MatchFileParser.parse("matches: []\n", path: "match/a.yml").snippets.isEmpty)
        XCTAssertTrue(try MatchFileParser.parse("matches:\n", path: "match/a.yml").snippets.isEmpty)
    }

    func testItemsAtColumnZeroAndNoTrailingNewline() throws {
        let text = "matches:\n- trigger: a\n  replace: A\n- trigger: b\n  replace: B"
        let parsed = try MatchFileParser.parse(text, path: "match/a.yml")
        XCTAssertEqual(parsed.snippets.map(\.sourceRange), [LineRange(first: 2, last: 3), LineRange(first: 4, last: 5)])
        XCTAssertEqual(parsed.snippets[1].source, "- trigger: b\n  replace: B")
    }

    func testTriggerComesBeforeTriggers() throws {
        let text = "matches:\n  - triggers: [b, c]\n    trigger: a\n    replace: x\n"
        let parsed = try MatchFileParser.parse(text, path: "match/a.yml")
        XCTAssertEqual(parsed.snippets[0].triggers, ["a", "b", "c"])
    }

    func testInvalidYAMLReportsTheLine() throws {
        let text = try String(contentsOf: fixtureURL("sample/match/broken.yml"), encoding: .utf8)
        XCTAssertThrowsError(try MatchFileParser.parse(text, path: "match/broken.yml")) { error in
            let failure = error as? MatchFileError
            XCTAssertNotNil(failure?.line)
            XCTAssertFalse(failure?.message.isEmpty ?? true)
        }
    }

    func testWrongShapeIsAnError() {
        XCTAssertThrowsError(try MatchFileParser.parse("- just\n- a list\n", path: "match/a.yml"))
        XCTAssertThrowsError(try MatchFileParser.parse("matches: nope\n", path: "match/a.yml"))
    }
}

final class ConfigLoaderTests: XCTestCase {
    private func sample() throws -> ConfigSnapshot {
        ConfigLoader(root: try fixtureURL("sample")).load()
    }

    func testEveryMatchAppearsInTheRightSet() throws {
        let snapshot = try sample()
        let counts = Dictionary(uniqueKeysWithValues: snapshot.sets.map { ($0.id, $0.snippets.count) })
        XCTAssertEqual(counts, [
            "personal.yml": 3,
            "work.yml": 12,
            "_email-signatures.yml": 2,
            "autocorrect.yml": 3,
            "accent-shortcuts.yml": 2,
            "broken.yml": 0,
            "packages/demo-symbols": 3,
        ])
        let work = try XCTUnwrap(snapshot.sets.first { $0.id == "work.yml" })
        XCTAssertEqual(work.snippets.first?.abbreviation, ";agenda")
        XCTAssertTrue(work.snippets.allSatisfy { $0.id.file == "match/work.yml" })
    }

    func testKindsNamesAndOrder() throws {
        let snapshot = try sample()
        XCTAssertEqual(
            snapshot.sets(ofKind: .abbreviations).map(\.name),
            ["Autocorrect", "Broken", "Email signatures", "Personal", "Work"]
        )
        XCTAssertEqual(snapshot.sets(ofKind: .regularExpressions).map(\.name), ["Accent shortcuts"])
        XCTAssertEqual(snapshot.sets(ofKind: .package).map(\.name), ["demo-symbols"])
    }

    func testUnderscoreFileIsOff() throws {
        let snapshot = try sample()
        let off = snapshot.sets.filter { !$0.isEnabled }
        XCTAssertEqual(off.map(\.id), ["_email-signatures.yml"])
    }

    func testPackageIsLockedAndSkipsItsManifest() throws {
        let package = try XCTUnwrap(try sample().sets.first { $0.kind == .package })
        XCTAssertTrue(package.isLocked)
        XCTAssertTrue(package.isEnabled)
        XCTAssertEqual(package.files.map(\.path), ["match/packages/demo-symbols/package.yml"])
        XCTAssertEqual(package.packageVersion, "0.2.0")
        XCTAssertFalse(try sample().sets.contains { $0.kind != .package && $0.isLocked })
    }

    func testBrokenFileStillAppearsWithAnError() throws {
        let broken = try XCTUnwrap(try sample().sets.first { $0.id == "broken.yml" })
        XCTAssertTrue(broken.isBroken)
        XCTAssertEqual(broken.problems.first?.file, "match/broken.yml")
        XCTAssertNotNil(broken.problems.first?.line)
        XCTAssertEqual(try sample().sets.filter(\.isBroken).count, 1)
    }

    func testConfigFiles() throws {
        let files = try sample().configFiles
        XCTAssertEqual(files.map(\.path), ["config/default.yml", "config/mail.yml"])
        XCTAssertTrue(files[0].isDefault)
        XCTAssertFalse(files[0].hasFilter)
        XCTAssertEqual(files[0].keys, ["toggle_key", "search_shortcut", "show_notifications"])
        XCTAssertEqual(files[1].filterClass, "^com\\.apple\\.mail$")
        XCTAssertEqual(files[1].extraIncludes, ["../match/_email-signatures.yml"])
        XCTAssertEqual(files[1].extraExcludes, ["../match/autocorrect.yml"])
        XCTAssertNil(files[1].problem)
    }

    func testNestedFoldersAndMissingFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ConfigLoader(root: root).load().sets.isEmpty)

        let nested = root.appendingPathComponent("match/team/shared")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "matches:\n  - trigger: x\n    replace: y\n".write(
            to: nested.appendingPathComponent("_replies.yaml"), atomically: true, encoding: .utf8
        )
        try "not yaml".write(to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let sets = ConfigLoader(root: root).load().sets
        XCTAssertEqual(sets.map(\.id), ["team/shared/_replies.yaml"])
        XCTAssertEqual(sets.first?.name, "Replies")
        XCTAssertEqual(sets.first?.isEnabled, false)
        XCTAssertEqual(sets.first?.snippets.first?.id.file, "match/team/shared/_replies.yaml")
    }

    func testLoadingDoesNotChangeTheFolder() throws {
        let root = try fixtureURL("sample")
        func listing() throws -> [String: Date] {
            var result: [String: Date] = [:]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            for case let url as URL in enumerator! {
                result[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            return result
        }
        let before = try listing()
        _ = ConfigLoader(root: root).load()
        XCTAssertEqual(try listing(), before)
    }
}
