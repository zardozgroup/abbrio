import XCTest
@testable import SnippetModel

final class QuickSearchTests: XCTestCase {
    private func snippet(
        _ index: Int, file: String = "match/work.yml", _ triggers: [String], _ expansion: Expansion,
        label: String? = nil, terms: [String] = [], variables: [SnippetVariable] = [], regex: String? = nil
    ) -> Snippet {
        Snippet(
            id: .init(file: file, index: index), triggers: triggers, regex: regex, expansion: expansion,
            label: label, searchTerms: terms, variables: variables
        )
    }

    private func set(_ name: String, _ snippets: [Snippet], enabled: Bool = true, info: SetInfo = SetInfo()) -> SnippetSet {
        var set = SnippetSet(
            id: name.lowercased() + ".yml", name: name, kind: .abbreviations, isEnabled: enabled,
            files: [SetFile(path: "match/\(name.lowercased()).yml", url: URL(fileURLWithPath: "/tmp/\(name).yml"))],
            snippets: snippets
        )
        set.info = info
        return set
    }

    // MARK: Insertion plans

    func testPlainTextIsPasted() {
        XCTAssertEqual(snippet(0, [";ty"], .text("Thank you!")).insertionPlan, .paste(text: "Thank you!", cursorBack: 0))
    }

    func testCursorMarkerIsRemovedAndCounted() {
        let plan = snippet(0, [";br"], .text("Dear $|$,\nBest")).insertionPlan
        XCTAssertEqual(plan, .paste(text: "Dear ,\nBest", cursorBack: 6))
    }

    func testCursorStepsCountCharactersNotCodeUnits() {
        let plan = snippet(0, [";e"], .text("a$|$👍🏽é")).insertionPlan
        XCTAssertEqual(plan, .paste(text: "a👍🏽é", cursorBack: 2))
    }

    func testAnythingElseGoesThroughTheEngine() {
        let date = SnippetVariable(name: "d", type: "date", parameters: ["format": "%Y"])
        XCTAssertEqual(snippet(0, [";d"], .text("{{d}}"), variables: [date]).insertionPlan, .engine(trigger: ";d"))
        // A reference with no variable of its own is a global variable.
        XCTAssertEqual(snippet(0, [";g"], .text("Hi {{name}}")).insertionPlan, .engine(trigger: ";g"))
        XCTAssertEqual(snippet(0, [";m"], .markdown("**x**")).insertionPlan, .engine(trigger: ";m"))
        XCTAssertEqual(snippet(0, [";h"], .html("<b>x</b>")).insertionPlan, .engine(trigger: ";h"))
        XCTAssertEqual(snippet(0, [";p"], .image(path: "/a.png")).insertionPlan, .engine(trigger: ";p"))
        XCTAssertEqual(snippet(0, [";f"], .form("Hi [[name]]")).insertionPlan, .engine(trigger: ";f"))
    }

    func testRegexHasNoPlan() {
        XCTAssertNil(snippet(0, [], .text("x"), regex: "a+").insertionPlan)
    }

    // MARK: Search

    func testSearchesTriggerLabelTermsAndExpansion() {
        let search = QuickSearch(sets: [set("Work", [
            snippet(0, ["tymail"], .text("Thank you for your email."), label: "Thanks reply"),
            snippet(1, [";sig"], .text("Kind regards"), terms: ["thankful"]),
            snippet(2, [";addr"], .text("1 Main Street")),
        ])])
        XCTAssertEqual(search.results(for: "thank").map(\.abbreviation), ["tymail", ";sig"])
        XCTAssertEqual(search.results(for: "main street").map(\.abbreviation), [";addr"])
        XCTAssertEqual(search.results(for: "\"street main\"").count, 0)
        XCTAssertEqual(search.results(for: "").count, 0)
    }

    func testAbbreviationMatchesComeFirst() {
        let search = QuickSearch(sets: [set("Work", [
            snippet(0, [";long"], .text("mentions ty in passing")),
            snippet(1, [";tyn"], .text("note")),
            snippet(2, ["ty"], .text("thanks")),
        ])])
        XCTAssertEqual(search.results(for: "ty").map(\.abbreviation), ["ty", ";tyn", ";long"])
    }

    func testSetSettingsLimitWhatIsSearched() {
        let items = [snippet(0, [";alpha"], .text("beta"), label: "gamma")]
        let noExpansions = QuickSearch(sets: [set("A", items, info: SetInfo(searchExpansions: false))])
        XCTAssertEqual(noExpansions.results(for: "beta").count, 0)
        XCTAssertEqual(noExpansions.results(for: "alpha").count, 1)
        XCTAssertEqual(noExpansions.results(for: "gamma").count, 1)

        let noAbbreviations = QuickSearch(sets: [set("A", items, info: SetInfo(searchAbbreviations: false))])
        XCTAssertEqual(noAbbreviations.results(for: "alpha").count, 0)
        XCTAssertEqual(noAbbreviations.results(for: "beta").count, 1)

        let neither = QuickSearch(sets: [set("A", items, info: SetInfo(searchAbbreviations: false, searchExpansions: false))])
        XCTAssertEqual(neither.results(for: "gamma").count, 0)
    }

    func testSetsThatAreOffAreLeftOut() {
        let search = QuickSearch(sets: [set("Off", [snippet(0, [";x"], .text("hello"))], enabled: false)])
        XCTAssertEqual(search.results(for: "hello").count, 0)
    }

    func testRegexItemsAreListedWithoutAPlan() {
        let search = QuickSearch(sets: [set("R", [snippet(0, [], .text("money"), regex: "\\d+usd")])])
        let results = search.results(for: "usd")
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].plan)
    }

    // MARK: Recents

    func testDotListsRecentItemsNewestFirst() {
        let sets = [set("Work", [
            snippet(0, [";a"], .text("one")), snippet(1, [";b"], .text("two")), snippet(2, [";c"], .text("three")),
        ])]
        var recents: [RecentUse] = []
        for (offset, trigger) in [";a", ";c", ";a", ";gone"].enumerated() {
            recents = RecentUse.adding(
                RecentUse(file: "match/work.yml", trigger: trigger, date: Date(timeIntervalSince1970: Double(offset))),
                to: recents
            )
        }
        XCTAssertEqual(recents.map(\.trigger), [";gone", ";a", ";c"])
        let search = QuickSearch(sets: sets, recents: recents)
        XCTAssertEqual(search.results(for: ".").map(\.abbreviation), [";a", ";c"])
        XCTAssertEqual(search.results(for: " . ").count, 2)
    }

    func testRecentListIsCapped() {
        var recents: [RecentUse] = []
        for index in 0..<60 {
            recents = RecentUse.adding(RecentUse(file: "f", trigger: "t\(index)", date: Date()), to: recents)
        }
        XCTAssertEqual(recents.count, 50)
        XCTAssertEqual(recents.first?.trigger, "t59")
    }
}
