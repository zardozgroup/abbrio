import XCTest
@testable import SnippetModel

final class RegexRuleTests: XCTestCase {
    // MARK: Reading a pattern

    func testNamedAndNumberedGroupsAreFound() {
        let analysis = RegexAnalysis(pattern: #":(?P<day>\d{2})/(\d{2})(?:x|y)\((?<tail>[()a-z]+)"#)
        XCTAssertEqual(analysis.groups.map(\.name), ["day", nil, "tail"])
        XCTAssertEqual(analysis.groups.map(\.number), [1, 2, 3])
        XCTAssertEqual(analysis.groupNames, ["day", "tail"])
        XCTAssertEqual(analysis.issues, [.plainNamedGroup])
    }

    func testWhatEspansoDoesNotSupportIsNamed() {
        XCTAssertEqual(RegexAnalysis(pattern: #"a(?=b)"#).issues, [.lookAhead])
        XCTAssertEqual(RegexAnalysis(pattern: #"a(?!b)"#).issues, [.lookAhead])
        XCTAssertEqual(RegexAnalysis(pattern: #"(?<=a)b(?<!c)"#).issues, [.lookBehind])
        XCTAssertEqual(RegexAnalysis(pattern: #"(a)\1"#).issues, [.backReference])
        XCTAssertEqual(RegexAnalysis(pattern: #"(?P<a>x)\k<a>"#).issues, [.backReference])
        XCTAssertEqual(RegexAnalysis(pattern: #"(?>a+)b"#).issues, [.atomicGroup])
        XCTAssertEqual(RegexAnalysis(pattern: #"a*+b"#).issues, [.possessiveQuantifier])
        XCTAssertEqual(RegexAnalysis(pattern: #"(?P<a>x)(?P<a>y)"#).issues, [.duplicateGroupName("a")])
        XCTAssertEqual(RegexAnalysis(pattern: #"(a"#).issues, [.unbalancedParentheses])
        XCTAssertEqual(RegexAnalysis(pattern: #"a)"#).issues, [.unbalancedParentheses])
    }

    func testEscapesAndClassesAreNotMistakenForSyntax() {
        // An escaped parenthesis, a parenthesis in a class, a lazy quantifier and a digit after an escaped backslash.
        let analysis = RegexAnalysis(pattern: #"\(a\)[(?=)]+?\\1[]x]\d"#)
        XCTAssertEqual(analysis.groups, [])
        XCTAssertEqual(analysis.issues, [])
    }

    func testMatchLengthsAreMeasured() {
        func lengths(_ pattern: String) -> [Int?] {
            let analysis = RegexAnalysis(pattern: pattern)
            return [analysis.minimumLength, analysis.maximumLength]
        }
        XCTAssertEqual(lengths("abc"), [3, 3])
        XCTAssertEqual(lengths(#":(?P<n>\d{2,4})usd"#), [6, 8])
        XCTAssertEqual(lengths("a|bcd"), [1, 3])
        XCTAssertEqual(lengths("=[a-z]+="), [3, nil])
        XCTAssertEqual(lengths("a?b*"), [0, nil])
        XCTAssertEqual(lengths(#"^\bab$"#), [2, 2])
        XCTAssertEqual(lengths("(ab){3}c{2,}"), [8, nil])
        XCTAssertEqual(lengths(#"\p{L}\x41éx{y"#), [6, 6])
        XCTAssertEqual(lengths("(?i)ab(?i:c)"), [3, 3])
    }

    func testLengthIsComparedWithWhatEspansoKeeps() {
        XCTAssertNil(RegexAnalysis(pattern: #":\d{2}"#).lengthRemark(limit: 30))
        XCTAssertEqual(RegexAnalysis(pattern: "=[a-z]+=").lengthRemark(limit: 30)?.isBlocking, false)
        XCTAssertEqual(RegexAnalysis(pattern: "a{10,40}").lengthRemark(limit: 30)?.isBlocking, false)
        XCTAssertEqual(RegexAnalysis(pattern: "a{31}").lengthRemark(limit: 30)?.isBlocking, true)
        XCTAssertNil(RegexAnalysis(pattern: "a{31}").lengthRemark(limit: 50))
    }

    // MARK: Trying a rule

    func testTheRuleFiresAtTheFirstMatchAndFillsInTheGroups() {
        let outcome = RegexTest.run(
            pattern: #":(?P<amount>\d+)(?P<unit>usd|eur);"#, expansion: .text("{{amount}} {{unit}}$|$ ({{clip}})"),
            sample: "pay :25eur; now", limit: 30
        )
        guard case .match(let match) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(match.before, "pay ")
        XCTAssertEqual(match.matched, ":25eur;")
        XCTAssertEqual(match.after, " now")
        XCTAssertEqual(match.groups, [.init(name: "amount", value: "25"), .init(name: "unit", value: "eur")])
        // Other dynamic content stays as written; the cursor marker is dropped.
        XCTAssertEqual(match.output, "25 eur ({{clip}})")
    }

    func testAnOpenEndedPatternFiresAsSoonAsItCan() {
        let outcome = RegexTest.run(pattern: #"x(?P<n>\d+)"#, expansion: .text("{{n}}"), sample: "x123", limit: 30)
        guard case .match(let match) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(match.matched, "x1")
        XCTAssertEqual(match.after, "23")
        XCTAssertEqual(match.output, "1")
    }

    func testOnlyTheLastCharactersTypedAreLookedAt() {
        let pattern = "=(?P<body>[a-z]+)="
        let long = "=" + String(repeating: "a", count: 38) + "="
        XCTAssertEqual(RegexTest.run(pattern: pattern, expansion: .text("x"), sample: long, limit: 30), .noMatch)
        guard case .match = RegexTest.run(pattern: pattern, expansion: .text("x"), sample: long, limit: 50) else {
            return XCTFail("expected a match with a longer limit")
        }
    }

    func testEmptyUnreadableAndOtherExpansions() {
        XCTAssertEqual(RegexTest.run(pattern: "", expansion: .text("x"), sample: "abc", limit: 30), .idle)
        XCTAssertEqual(RegexTest.run(pattern: "a", expansion: .text("x"), sample: "", limit: 30), .idle)
        XCTAssertEqual(RegexTest.run(pattern: "a", expansion: .text("x"), sample: "bbb", limit: 30), .noMatch)
        guard case .unreadable = RegexTest.run(pattern: "a(", expansion: .text("x"), sample: "a", limit: 30) else {
            return XCTFail("expected the pattern to be refused")
        }
        guard case .match(let match) = RegexTest.run(pattern: "a", expansion: .image(path: "p.png"), sample: "a", limit: 30) else {
            return XCTFail("expected a match")
        }
        XCTAssertNil(match.output)
    }

    // MARK: Converting

    func testNumberedGroupsBecomeNamedOnes() {
        let result = RegexConversion.convert(pattern: #":(\d+)-(\w+)-(z)"#, body: "$2 costs ${1}, $|$ $9 $")
        // The third group is not referred to, so it is left alone.
        XCTAssertEqual(result?.pattern, #":(?P<group1>\d+)-(?P<group2>\w+)-(z)"#)
        XCTAssertEqual(result?.body, "{{group2}} costs {{group1}}, $|$ $9 $")
    }

    func testPlainNamesAreRespelledAndKeepTheirNames() {
        let result = RegexConversion.convert(pattern: #"(?<day>\d\d)\.(\d\d)(?P<group2>x)"#, body: "${day}/$2/$1")
        XCTAssertEqual(result?.pattern, #"(?P<day>\d\d)\.(?P<group2_>\d\d)(?P<group2>x)"#)
        XCTAssertEqual(result?.body, "{{day}}/{{group2_}}/{{day}}")
    }

    func testNothingToConvert() {
        XCTAssertNil(RegexConversion.convert(pattern: #":(?P<n>\d+)(x)"#, body: "{{n}} for $5"))
        XCTAssertNil(RegexConversion.convert(pattern: "(a", body: "$1"))
    }
}
