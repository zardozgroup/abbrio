import XCTest
@testable import SnippetModel

final class DelimitedTextTests: XCTestCase {
    func testQuotedFieldsKeepDelimitersQuotesAndLineBreaks() {
        let text = "a,\"one, two\",x\r\nb,\"say \"\"hi\"\"\",\n\nc,\"line 1\r\nline 2\"\n"
        XCTAssertEqual(DelimitedText.rows(in: text, delimiter: .comma), [
            ["a", "one, two", "x"],
            ["b", "say \"hi\"", ""],
            ["c", "line 1\nline 2"],
        ])
    }

    func testAByteOrderMarkAndAMissingFinalLineBreakAreAccepted() {
        XCTAssertEqual(DelimitedText.rows(in: "\u{FEFF}a,b\nc,d", delimiter: .comma), [["a", "b"], ["c", "d"]])
    }

    func testTabsWinWhenEveryRecordHasOne() {
        XCTAssertEqual(DelimitedText.delimiter(of: ";sig\tBest regards, Robin\n;adr\t1 Main St, Springfield\n"), .tab)
        XCTAssertEqual(DelimitedText.delimiter(of: ";sig,\"Best\tregards\"\n;adr,1 Main St\n"), .comma)
        XCTAssertEqual(DelimitedText.delimiter(of: ""), .comma)
    }

    func testWritingQuotesOnlyWhatNeedsIt() {
        let rows = [["a", "one, two", ""], ["b ", "say \"hi\"", "two\nlines"]]
        let text = DelimitedText.text(for: rows, delimiter: .comma)
        XCTAssertEqual(text, "a,\"one, two\",\r\n\"b \",\"say \"\"hi\"\"\",\"two\nlines\"\r\n")
        XCTAssertEqual(DelimitedText.rows(in: text, delimiter: .comma), rows)
    }

    func testImportFindsTheHeaderAndSkipsIncompleteRows() {
        let source = SnippetImport(text: "Abbreviation,Expansion,Description\n;sig,Best regards,Sign-off\n;empty,\n,no trigger\n;adr,1 Main St\n")
        XCTAssertTrue(source.hasHeader)
        XCTAssertEqual(source.delimiter, .comma)
        XCTAssertEqual(source.rows.map(\.abbreviation), [";sig", ";adr"])
        XCTAssertEqual(source.rows.map(\.description), ["Sign-off", ""])
        XCTAssertEqual(source.skippedCount, 2)
        XCTAssertEqual(source.drafts.first, MatchDraft(triggers: [";sig"], expansion: .text("Best regards"), label: "Sign-off"))
    }

    func testImportWithoutAHeaderKeepsTheFirstRowAndTheChoiceCanBeForced() {
        let text = ";sig\tBest regards\n;adr\t1 Main St\n"
        XCTAssertFalse(SnippetImport(text: text).hasHeader)
        XCTAssertEqual(SnippetImport(text: text).rows.count, 2)
        XCTAssertEqual(SnippetImport(text: text, hasHeader: true).rows.map(\.abbreviation), [";adr"])
        XCTAssertEqual(SnippetImport(text: "abbreviation,expansion\n;a,b\n", hasHeader: false).rows.count, 2)
    }

    func testExportWritesOneRowPerAbbreviationAndReadsBack() {
        let snippets = [
            Snippet(id: .init(file: "a.yml", index: 0), triggers: [";sig", ";s"], expansion: .text("Best,\nRobin"), label: "Sign-off"),
            Snippet(id: .init(file: "a.yml", index: 1), triggers: [";pic"], expansion: .image(path: "/x.png")),
            Snippet(id: .init(file: "a.yml", index: 2), triggers: [], regex: "a+", expansion: .text("b")),
        ]
        let export = SnippetExport(snippets: snippets)
        XCTAssertEqual(export.text, "abbreviation,expansion,description\r\n;sig,\"Best,\nRobin\",Sign-off\r\n;s,\"Best,\nRobin\",Sign-off\r\n")
        XCTAssertEqual(export.rowCount, 2)
        XCTAssertEqual(export.skippedCount, 2)
        let back = SnippetImport(text: export.text)
        XCTAssertTrue(back.hasHeader)
        XCTAssertEqual(back.rows.map(\.abbreviation), [";sig", ";s"])
        XCTAssertEqual(back.rows.first?.expansion, "Best,\nRobin")
    }
}
