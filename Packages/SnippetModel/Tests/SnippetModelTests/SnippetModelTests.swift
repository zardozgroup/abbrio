import XCTest
@testable import SnippetModel

final class SearchQueryTests: XCTestCase {
    private let snippet = Snippet(
        id: .init(file: "match/work.yml", index: 0),
        triggers: ["btw", "Btw"],
        expansion: .text("by the way"),
        label: "Casual aside",
        searchTerms: ["incidentally", "café"]
    )

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(SearchQuery("").matches(snippet))
        XCTAssertTrue(SearchQuery("   ").isEmpty)
    }

    func testAllWordsMustAppearInAnyOrder() {
        XCTAssertTrue(SearchQuery("way by").matches(snippet))
        XCTAssertTrue(SearchQuery("aside btw").matches(snippet))
        XCTAssertFalse(SearchQuery("way missing").matches(snippet))
    }

    func testQuotedPhraseMustMatchExactly() {
        XCTAssertTrue(SearchQuery("\"by the way\"").matches(snippet))
        XCTAssertFalse(SearchQuery("\"the by\"").matches(snippet))
        XCTAssertTrue(SearchQuery("\"the way\" casual").matches(snippet))
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertTrue(SearchQuery("BTW").matches(snippet))
        XCTAssertTrue(SearchQuery("cafe").matches(snippet))
    }

    func testSearchTermsAndRegexAreSearched() {
        XCTAssertTrue(SearchQuery("incidentally").matches(snippet))
        let rule = Snippet(id: .init(file: "match/r.yml", index: 0), regex: "e'(?P<v>[aeiou])", expansion: .text("x"))
        XCTAssertTrue(SearchQuery("aeiou").matches(rule))
    }
}

final class DuplicateIndexTests: XCTestCase {
    private func set(_ id: String, name: String, enabled: Bool = true, triggers: [[String]]) -> SnippetSet {
        SnippetSet(
            id: id, name: name, kind: .abbreviations, isEnabled: enabled, files: [],
            snippets: triggers.enumerated().map { index, list in
                Snippet(id: .init(file: "match/" + id, index: index), triggers: list, expansion: .text("x"))
            }
        )
    }

    func testFindsTriggerSharedByTwoActiveSets() {
        let work = set("work.yml", name: "Work", triggers: [["teh"], ["btw"]])
        let auto = set("autocorrect.yml", name: "AutoCorrect", triggers: [["teh"]])
        let index = DuplicateIndex(sets: [work, auto])

        XCTAssertEqual(index.conflicts(for: work.snippets[0].id), [.init(trigger: "teh", otherSetNames: ["AutoCorrect"])])
        XCTAssertTrue(index.conflicts(for: work.snippets[1].id).isEmpty)
        XCTAssertTrue(index.hasConflicts(in: auto))
        XCTAssertEqual(index.conflicts(in: work).map(\.trigger), ["teh"])
    }

    func testIgnoresSetsThatAreOff() {
        let work = set("work.yml", name: "Work", triggers: [["teh"]])
        let off = set("_old.yml", name: "Old", enabled: false, triggers: [["teh"]])
        let index = DuplicateIndex(sets: [work, off])
        XCTAssertFalse(index.hasConflicts(in: work))
        XCTAssertFalse(index.hasConflicts(in: off))
    }

    func testTriggersAreCaseSensitive() {
        let a = set("a.yml", name: "A", triggers: [["btw"]])
        let b = set("b.yml", name: "B", triggers: [["BTW"]])
        XCTAssertFalse(DuplicateIndex(sets: [a, b]).hasConflicts(in: a))
    }

    func testClashInsideOneSetHasNoOtherSetNames() {
        let a = set("a.yml", name: "A", triggers: [["x"], ["x", "y"]])
        let index = DuplicateIndex(sets: [a])
        XCTAssertEqual(index.conflicts(for: a.snippets[0].id), [.init(trigger: "x", otherSetNames: [])])
    }
}

final class EngineVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(EngineVersion(parsing: "2.4.1\n"), EngineVersion(major: 2, minor: 4, patch: 1))
        XCTAssertEqual(EngineVersion(parsing: "espanso 2.3.0"), EngineVersion(major: 2, minor: 3, patch: 0))
        XCTAssertNil(EngineVersion(parsing: "unknown"))
    }

    func testFeatureGates() {
        let old = EngineVersion(major: 2, minor: 2, patch: 9)
        let middle = EngineVersion(major: 2, minor: 3, patch: 0)
        let current = EngineVersion(major: 2, minor: 4, patch: 1)
        XCTAssertFalse(old.supportsYAMLExtension)
        XCTAssertTrue(middle.supportsDateTimeZone)
        XCTAssertFalse(middle.supportsStatistics)
        XCTAssertTrue(current.supportsStatistics)
        XCTAssertTrue(current.isSupported)
        XCTAssertFalse(EngineVersion(major: 1, minor: 9, patch: 0).isSupported)
    }
}

final class DisplayNameTests: XCTestCase {
    func testNamesFromFileNames() {
        XCTAssertEqual(SnippetSet.displayName(forFileName: "work.yml"), "Work")
        XCTAssertEqual(SnippetSet.displayName(forFileName: "_email-signatures.yml"), "Email signatures")
        XCTAssertEqual(SnippetSet.displayName(forFileName: "accent_shortcuts.yaml"), "Accent shortcuts")
        XCTAssertEqual(SnippetSet.displayName(forFileName: "demo-symbols"), "Demo symbols")
    }
}

final class ExpansionPreviewTests: XCTestCase {
    private let preview = ExpansionPreview(
        now: Date(timeIntervalSince1970: 1_794_400_920), // 2026-11-11 12:42 UTC
        timeZone: TimeZone(identifier: "UTC")!
    )

    private func snippet(_ expansion: Expansion, _ variables: [SnippetVariable] = []) -> Snippet {
        Snippet(id: .init(file: "match/a.yml", index: 0), triggers: ["x"], expansion: expansion, variables: variables)
    }

    func testFirstLineOnly() {
        XCTAssertEqual(preview.text(for: snippet(.text("Hello\nWorld"))), "Hello")
        XCTAssertEqual(preview.text(for: snippet(.text("\n  Indented\nrest"))), "Indented")
    }

    func testDateIsRendered() {
        let date = SnippetVariable(name: "today", type: "date", parameters: ["format": "%Y-%m-%d %H:%M"])
        XCTAssertEqual(preview.text(for: snippet(.text("{{today}}"), [date])), "{Date: 2026-11-11 12:42}")
        let tomorrow = SnippetVariable(name: "t", type: "date", parameters: ["format": "%d", "offset": "86400"])
        XCTAssertEqual(preview.text(for: snippet(.text("{{t}}"), [tomorrow])), "{Date: 12}")
    }

    func testOtherVariableKinds() {
        let variables = [
            SnippetVariable(name: "clip", type: "clipboard"),
            SnippetVariable(name: "branch", type: "shell", parameters: ["cmd": "git branch --show-current"]),
            SnippetVariable(name: "form1", type: "form"),
        ]
        XCTAssertEqual(preview.text(for: snippet(.text("Link: {{clip}}"), variables)), "Link: {Clipboard}")
        XCTAssertEqual(preview.text(for: snippet(.text("{{branch}}"), variables)), "{Shell: git branch --show-current}")
        XCTAssertEqual(
            preview.text(for: snippet(.text("Dear {{form1.first_name}} {{form1.last_name}},"), variables)),
            "Dear {First name} {Last name},"
        )
        XCTAssertEqual(preview.text(for: snippet(.text("{{unknown}}"))), "{unknown}")
    }

    func testFormAndPicture() {
        XCTAssertEqual(preview.text(for: snippet(.form("Hi [[first_name]]"))), "Hi {First name}")
        XCTAssertEqual(preview.text(for: snippet(.image(path: "/tmp/images/logo.png"))), "logo.png")
    }

    func testReferenceScanningMatchesThePattern() {
        // The scanner replaced the patterns {{ name }} and [[ name ]]; it must find exactly what they found.
        let variables = /\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/
        let fields = /\[\[\s*([A-Za-z0-9_]+)\s*\]\]/
        let samples = [
            "", "plain text", "{{a}}", "{{ a }}", "{{\ta.b}}", "x{{a}}y{{b}}z", "{{}}", "{{ }}", "{a}",
            "{{{a}}}", "{{a}", "{{a b}}", "{{a-b}}", "{{é}}", "{{a}}}}", "[[f]]", "[[ f ]]", "[[f.g]]",
            "[[[f]]]", "[[f]", "{{a}} [[f]]", "{{ {{a}} }}",
        ]
        for sample in samples {
            XCTAssertEqual(
                ExpansionPreview.replacingReferences(in: sample, open: "{{", close: "}}", allowingDots: true) { "<\($0)>" },
                sample.replacing(variables) { "<\($0.1)>" },
                sample
            )
            XCTAssertEqual(
                ExpansionPreview.replacingReferences(in: sample, open: "[[", close: "]]", allowingDots: false) { "<\($0)>" },
                sample.replacing(fields) { "<\($0.1)>" },
                sample
            )
        }
    }
}
