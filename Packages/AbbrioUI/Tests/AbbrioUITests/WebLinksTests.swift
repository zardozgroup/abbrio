import XCTest
@testable import AbbrioUI

final class WebLinksTests: XCTestCase {
    private func links(in markdown: String) -> [String] {
        var text = try! AttributedString(markdown: markdown)
        WebLinks.keepOnlyWebLinks(in: &text)
        return text.runs.compactMap { $0.link?.absoluteString }
    }

    func testOnlyWebLinksStayLinks() {
        XCTAssertEqual(links(in: "[site](https://getabbrio.com) and [plain](http://example.invalid)"), [
            "https://getabbrio.com", "http://example.invalid",
        ])
        XCTAssertEqual(links(in: "[file](file:///etc/hosts) [js](javascript:alert(1)) [app](x-apple.systempreferences:x) [mail](mailto:a@example.invalid)"), [])
    }

    func testTheTextOfARemovedLinkStays() {
        var text = try! AttributedString(markdown: "Open [this](file:///etc/hosts) now")
        WebLinks.keepOnlyWebLinks(in: &text)
        XCTAssertEqual(String(text.characters), "Open this now")
    }

    func testReadmeBlocksUseTheSameFilter() {
        let blocks = MarkdownBlock.blocks(in: "See [docs](https://getabbrio.com/help/) or [local](file:///tmp/x)")
        let links = blocks.flatMap { $0.text.runs.compactMap { $0.link?.absoluteString } }
        XCTAssertEqual(links, ["https://getabbrio.com/help/"])
    }
}
