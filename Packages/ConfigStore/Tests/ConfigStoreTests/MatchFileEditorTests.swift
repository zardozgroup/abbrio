import XCTest
import SnippetModel
@testable import ConfigStore

final class MatchFileEditorTests: XCTestCase {
    private let path = "match/commented.yml"

    private func fixture(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.resourceURL)
        return try Data(contentsOf: base.appendingPathComponent("Fixtures/golden").appendingPathComponent(name))
    }

    private func snippets(_ data: Data) throws -> [Snippet] {
        try MatchFileParser.parse(String(decoding: data, as: UTF8.self), path: path).snippets
    }

    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    /// Fails unless every line before `range.first` and after `range.last` of the original is still there,
    /// byte for byte.
    private func assertOnlyLines(
        _ range: ClosedRange<Int>, changedFrom before: Data, to after: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let old = lines(before), new = lines(after)
        let head = Array(old[..<(range.lowerBound - 1)])
        let tail = Array(old[range.upperBound...])
        XCTAssertEqual(Array(new.prefix(head.count)), head, "lines above the match changed", file: file, line: line)
        XCTAssertEqual(Array(new.suffix(tail.count)), tail, "lines below the match changed", file: file, line: line)
        XCTAssertNotEqual(before, after, file: file, line: line)
    }

    private func edit(_ index: Int, in data: Data, _ change: (inout MatchDraft) -> Void) throws -> Data {
        var draft = MatchDraft(try XCTUnwrap(try snippets(data).first { $0.id.index == index }))
        change(&draft)
        return try MatchFileEditor.update(matchAt: index, with: draft, in: data, path: path)
    }

    // MARK: Editing one match

    func testEditingALabelMatchesTheGoldenFile() throws {
        let before = try fixture("commented.yml")
        let after = try edit(0, in: before) { $0.label = "Opening reply" }
        XCTAssertEqual(String(decoding: after, as: UTF8.self),
                       String(decoding: try fixture("commented.label-edited.yml"), as: UTF8.self))
        assertOnlyLines(14...16, changedFrom: before, to: after)
    }

    func testEditingChangesOnlyTheChangedKey() throws {
        let before = try fixture("commented.yml")
        let after = try edit(0, in: before) { $0.body = "Hello!" }
        // The trigger line and the label line, with its comment, are untouched.
        XCTAssertEqual(lines(after)[13], "  - trigger: \";hello\"")
        XCTAssertEqual(lines(after)[14], "    replace: \"Hello!\"")
        XCTAssertEqual(lines(after)[15], "    label: First reply   # shown in search")
        assertOnlyLines(15...15, changedFrom: before, to: after)
    }

    func testEditingABlockKeepsTheCommentInsideTheMatch() throws {
        let before = try fixture("commented.yml")
        let after = try edit(1, in: before) { $0.body = "One line.\nSecond line.\n" }
        XCTAssertEqual(Array(lines(after)[17...22]), [
            "  - trigger: \";wait\"",
            "    # how long we usually take",
            "    replace: |",
            "      One line.",
            "      Second line.",
            "    word: true",
        ])
        assertOnlyLines(20...23, changedFrom: before, to: after)
        XCTAssertEqual(try snippets(after)[1].expansion, .text("One line.\nSecond line.\n"))
    }

    func testOptionsAreAddedAndRemoved() throws {
        let before = try fixture("commented.yml")
        var after = try edit(1, in: before) { $0.options.word = false }
        XCTAssertFalse(lines(after).contains("    word: true"))
        assertOnlyLines(24...24, changedFrom: before, to: after)

        after = try edit(0, in: before) {
            $0.options.word = true
            $0.options.forceMode = .clipboard
        }
        XCTAssertEqual(Array(lines(after)[13...17]), [
            "  - trigger: \";hello\"",
            "    replace: \"Hello, and thanks for getting in touch.\"",
            "    label: First reply   # shown in search",
            "    word: true",
            "    force_mode: clipboard",
        ])
        assertOnlyLines(14...16, changedFrom: before, to: after)
    }

    func testAliasesBecomeATriggerListAndBack() throws {
        let before = try fixture("commented.yml")
        let withAlias = try edit(0, in: before) { $0.aliases = [";hi"] }
        XCTAssertEqual(lines(withAlias)[13], "  - triggers: [\";hello\", \";hi\"]")
        XCTAssertEqual(try snippets(withAlias)[0].triggers, [";hello", ";hi"])

        let single = try edit(2, in: before) { $0.aliases = [] }
        XCTAssertEqual(lines(single)[26], "  - trigger: \";bye\"")
        // The quoting the author chose for the untouched keys stays.
        XCTAssertEqual(lines(single)[27], "    replace: 'Kind regards, {{desk}}'")
        XCTAssertEqual(try snippets(single)[2].variables.map(\.name), ["desk"])
        assertOnlyLines(27...27, changedFrom: before, to: single)
    }

    func testNonASCIITextAndTheLastMatch() throws {
        let before = try fixture("commented.yml")
        let after = try edit(3, in: before) { $0.body = "Deux cafés — ☕☕" }
        XCTAssertEqual(lines(after)[33], "    replace: \"Deux cafés — ☕☕\"")
        assertOnlyLines(33...34, changedFrom: before, to: after)
        XCTAssertEqual(lines(after).suffix(3), ["", "# Checked every spring.", ""])
    }

    func testWindowsLineEndingsAreKept() throws {
        let unix = try fixture("commented.yml")
        let before = Data(String(decoding: unix, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let after = try edit(0, in: before) { $0.label = "Opening reply" }
        let expected = String(decoding: try fixture("commented.label-edited.yml"), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(String(decoding: after, as: UTF8.self), expected)
    }

    func testByteOrderMarkAndMissingFinalNewlineAreKept() throws {
        let text = "\u{FEFF}matches:\n  - trigger: a\n    replace: A"
        let after = try edit(0, in: Data(text.utf8)) { $0.body = "B" }
        XCTAssertEqual(String(decoding: after, as: UTF8.self), "\u{FEFF}matches:\n  - trigger: a\n    replace: B")
    }

    func testAnUnchangedDraftChangesNothing() throws {
        let before = try fixture("commented.yml")
        XCTAssertEqual(try edit(2, in: before) { _ in }, before)
    }

    func testAdvancedYAMLIsRefused() throws {
        let base = try XCTUnwrap(Bundle.module.resourceURL)
        let data = try Data(contentsOf: base.appendingPathComponent("Fixtures/files/edge-cases.yml"))
        for index in [2, 3, 4, 5] {
            XCTAssertThrowsError(try edit(index, in: data) { $0.label = "x" }) { error in
                guard case .notEditable = error as? EditError else { return XCTFail("\(error)") }
            }
        }
        // The plain ones in the same file can be edited.
        let after = try edit(0, in: data) { $0.body = "1st" }
        assertOnlyLines(9...9, changedFrom: data, to: after)
    }

    func testOddLayoutsAreLeftToTheYAMLTab() throws {
        let dashAlone = "matches:\n  -\n    trigger: a\n    replace: A\n"
        let wideDash = "matches:\n  -   trigger: a\n      replace: A\n"
        for text in [dashAlone, wideDash] {
            let parsed = try MatchFileParser.parse(text, path: path)
            XCTAssertEqual(parsed.snippets.first?.needsAdvancedYAML, true, text)
        }
    }

    func testEmptyAbbreviationIsRefused() throws {
        let before = try fixture("commented.yml")
        XCTAssertThrowsError(try edit(0, in: before) { $0.abbreviation = "" }) { error in
            guard case .invalidDraft = error as? EditError else { return XCTFail("\(error)") }
        }
    }

    // MARK: Text that is easy to get wrong

    func testAwkwardStringsSurviveARoundTrip() throws {
        let strings = [
            "yes", "No", "null", "~", "123", "1.5", "2024-01-31", "0x1F", "true",
            "a: b", "a # b", "# not a comment", " leading space", "trailing space ", "",
            "- dash", "* star", "& and", "! bang", "| pipe", "> fold", "% percent", "@ at", "` tick",
            "{{clipboard}}", "[[field]]", "$|$", "{braces}", "[brackets]", "a, b",
            "say \"hi\"", "it's", "back\\slash", "tab\there",
            "two\nlines", "ends with a break\n", "ends with two\n\n", "\nstarts with a break",
            "  indented first line\nsecond", "blank\n\nin the middle", "trailing space \nin a line",
            "naïve café — ☕", "emoji 👍🏽", "line separator\u{2028}inside", "bell\u{07}",
            "key: value\nother: thing", "# heading\ntext", "---", "...", "a\r\nb",
        ]
        var data = Data(MatchFileEditor.emptyFileText.utf8)
        for (index, string) in strings.enumerated() {
            let draft = MatchDraft(
                triggers: [";t\(index)", string.isEmpty ? "x" : string],
                expansion: .text(string), label: string, searchTerms: string.isEmpty ? [] : [string, "plain"]
            )
            let result = try MatchFileEditor.append(draft, to: data, path: path)
            data = result.data
            XCTAssertEqual(result.index, index)
        }
        let parsed = try snippets(data)
        XCTAssertEqual(parsed.count, strings.count)
        for (snippet, string) in zip(parsed, strings) {
            XCTAssertEqual(snippet.expansion, .text(string))
            XCTAssertEqual(snippet.label ?? "", string)
            XCTAssertFalse(snippet.needsAdvancedYAML, "\(string.debugDescription) should stay editable")
        }

        // Each one can also be written over an existing value.
        for (index, string) in strings.enumerated() {
            data = try edit(index, in: data) { $0.body = string + "!" }
            XCTAssertEqual(try snippets(data)[index].expansion, .text(string + "!"))
        }
    }

    func testPlainWordsAreNotQuoted() throws {
        let draft = MatchDraft(triggers: ["btw"], expansion: .text("by the way"), label: "By the way")
        let text = String(decoding: try MatchFileEditor.append(draft, to: Data("matches: []\n".utf8), path: path).data, as: UTF8.self)
        XCTAssertEqual(text, "matches:\n  - trigger: btw\n    replace: by the way\n    label: By the way\n")
    }

    // MARK: Adding

    func testAppendGoesAfterTheLastMatchAndKeepsTheRest() throws {
        let before = try fixture("commented.yml")
        let draft = MatchDraft(triggers: [";new"], expansion: .text("Added"), options: {
            var options = SnippetOptions()
            options.word = true
            return options
        }())
        let (after, index) = try MatchFileEditor.append(draft, to: before, path: path)
        XCTAssertEqual(index, 4)
        XCTAssertEqual(Array(lines(after)[32...39]), [
            "  - trigger: \";café\"",
            "    replace: \"Un café — ☕, s'il vous plaît\"",
            "  - trigger: \";new\"",
            "    replace: Added",
            "    word: true",
            "",
            "# Checked every spring.",
            "",
        ])
        XCTAssertEqual(Array(lines(after).prefix(34)), Array(lines(before).prefix(34)))
    }

    func testAppendToFilesWithoutMatches() throws {
        let draft = MatchDraft(triggers: ["a"], expansion: .text("A"))
        func appended(_ text: String) throws -> String {
            String(decoding: try MatchFileEditor.append(draft, to: Data(text.utf8), path: path).data, as: UTF8.self)
        }
        let item = "matches:\n  - trigger: a\n    replace: A\n"
        XCTAssertEqual(try appended("matches: []\n"), item)
        XCTAssertEqual(try appended("matches:\n"), item)
        XCTAssertEqual(try appended(""), item)
        XCTAssertEqual(try appended("# notes\nimports:\n  - x.yml\n"), "# notes\nimports:\n  - x.yml\n\n" + item)
        XCTAssertEqual(try appended("matches: []\nglobal_vars: []\n"), item + "global_vars: []\n")
    }

    func testAppendFollowsTheFilesSpacingAndIndentation() throws {
        let draft = MatchDraft(triggers: ["c"], expansion: .text("C"))
        let spaced = "matches:\n- trigger: a\n  replace: A\n\n- trigger: b\n  replace: B\n"
        let after = try MatchFileEditor.append(draft, to: Data(spaced.utf8), path: path).data
        XCTAssertEqual(String(decoding: after, as: UTF8.self), spaced + "\n- trigger: c\n  replace: C\n")
    }

    func testDuplicateCopiesTheLinesAsWritten() throws {
        let before = try fixture("commented.yml")
        let (after, index) = try MatchFileEditor.duplicate(matchAt: 2, in: before, path: path)
        XCTAssertEqual(index, 3)
        let parsed = try snippets(after)
        XCTAssertEqual(parsed.map(\.abbreviation), [";hello", ";wait", ";bye", ";bye", ";café"])
        XCTAssertEqual(parsed[3].source, parsed[2].source)
        XCTAssertEqual(parsed[3].variables.map(\.name), ["desk"])
        XCTAssertEqual(Array(lines(after).prefix(32)), Array(lines(before).prefix(32)))
        XCTAssertEqual(Array(lines(after).suffix(5)), Array(lines(before).suffix(5)))
    }

    // MARK: Deleting

    func testDeleteTakesTheCommentAboveAndNothingElse() throws {
        let before = try fixture("commented.yml")
        let after = try MatchFileEditor.delete(matchAt: 0, in: before, path: path)
        var expected = lines(before)
        expected.removeSubrange(12...16)   // the comment, three lines of the match, one blank line
        XCTAssertEqual(lines(after), expected)
        XCTAssertEqual(try snippets(after).map(\.abbreviation), [";wait", ";bye", ";café"])
    }

    func testDeletingTheOnlyMatchLeavesAnEmptyList() throws {
        let text = "# top\nmatches:\n  - trigger: a\n    replace: A\n"
        let after = try MatchFileEditor.delete(matchAt: 0, in: Data(text.utf8), path: path)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), "# top\nmatches: []\n")
    }

    // MARK: YAML editing

    func testReplacingTheSourceOfOneMatch() throws {
        let before = try fixture("commented.yml")
        let yaml = "  - trigger: \";hello\"\n    replace: Hi\n    custom: kept\n"
        let after = try MatchFileEditor.replaceSource(ofMatchAt: 0, with: yaml, in: before, path: path)
        assertOnlyLines(14...16, changedFrom: before, to: after)
        XCTAssertEqual(try snippets(after)[0].unknownKeys, ["custom"])

        XCTAssertThrowsError(
            try MatchFileEditor.replaceSource(ofMatchAt: 0, with: "  - trigger: \"open", in: before, path: path)
        ) { error in
            guard case .invalidYAML = error as? EditError else { return XCTFail("\(error)") }
        }
    }
}
