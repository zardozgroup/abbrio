import XCTest
import SnippetModel
@testable import AbbrioUI

final class RowSortingTests: XCTestCase {
    /// Texts that tell the comparison options apart: case, digits, width, accents, symbols, ties.
    private static let samples = [
        "abc", "ABC", "Abc", "abd", "ab", "a b", "a-b", "a_b", "file2", "file10", "File1", "file01", "x9", "x09",
        "ａｂｃ", "café", "cafe", "Café", "cafë", "ß", "ss", "Straße", "strasse", "élan", "elan", "Zebra", "zebra",
        "über", "uber", ";ty", ";Ty", ":)", "😀", "😀a", "", " ", "1", "01", "001", "-1", "1.5", "1,5", "日本", "にほん",
        "teh", "the", "hte", "abc",
    ]

    private func rows(_ texts: [(String, String, String)]) -> [SnippetRow] {
        texts.enumerated().map { index, text in
            let snippet = Snippet(
                id: .init(file: "match/a.yml", index: index), triggers: [text.0], expansion: .text(text.1),
                label: text.2.isEmpty ? nil : text.2
            )
            return SnippetRow(snippet: snippet, setName: "A", isDuplicate: false, preview: ExpansionPreview())
        }
    }

    private func mixed(_ count: Int) -> [SnippetRow] {
        let samples = Self.samples
        return rows((0..<count).map { i in
            (samples[i % samples.count] + (i % 7 == 0 ? "" : samples[(i / 3) % samples.count]),
             samples[(i * 5) % samples.count],
             samples[(i * 11) % samples.count])
        })
    }

    func testMatchesSortUsingForEveryColumnAndDirection() {
        let input = mixed(2_000)
        let orders: [[KeyPathComparator<SnippetRow>]] = [
            [KeyPathComparator(\.abbreviation)],
            [KeyPathComparator(\.abbreviation, order: .reverse)],
            [KeyPathComparator(\.expansion)],
            [KeyPathComparator(\.description, order: .reverse)],
            [KeyPathComparator(\.description), KeyPathComparator(\.abbreviation, order: .reverse)],
        ]
        for order in orders {
            var fast = input
            fast.sortRows(using: order)
            XCTAssertEqual(fast.map(\.id), input.sorted(using: order).map(\.id), "\(order)")
        }
    }

    func testOtherComparatorsFallBack() {
        let input = mixed(500)
        let order = [KeyPathComparator(\SnippetRow.abbreviation, comparator: String.StandardComparator.lexical)]
        var sorted = input
        sorted.sortRows(using: order)
        XCTAssertEqual(sorted.map(\.id), input.sorted(using: order).map(\.id))
    }

    func testLargeSetIsMuchFaster() {
        let input = mixed(75_000)
        let order = [KeyPathComparator(\SnippetRow.abbreviation)]
        let clock = ContinuousClock()
        var fast = input
        let fastTime = clock.measure { fast.sortRows(using: order) }
        var slow = input
        let slowTime = clock.measure { slow.sort(using: order) }
        XCTAssertEqual(fast.map(\.id), slow.map(\.id))
        print("75,000 rows: sortRows \(fastTime), sort(using:) \(slowTime)")
        XCTAssertLessThan(fastTime, slowTime / 2)
    }
}
