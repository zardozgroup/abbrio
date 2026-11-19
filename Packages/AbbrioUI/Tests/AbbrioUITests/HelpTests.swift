import XCTest
@testable import AbbrioUI

final class HelpTests: XCTestCase {
    func testEachChoiceLeadsToItsPage() {
        XCTAssertEqual(HelpDestination.allCases, [.helpCenter, .supportRequest, .bugReport])
        XCTAssertEqual(HelpDestination.helpCenter.url.absoluteString, "https://getabbrio.com/help/")
        XCTAssertEqual(
            HelpDestination.supportRequest.url.absoluteString,
            "https://github.com/zardozgroup/abbrio/issues/new?template=general-support-request.md"
        )
        XCTAssertEqual(
            HelpDestination.bugReport.url.absoluteString,
            "https://github.com/zardozgroup/abbrio/issues/new?template=bug_report.md"
        )
    }

    func testEveryChoiceHasWordingAndASecureAddress() {
        for destination in HelpDestination.allCases {
            XCTAssertEqual(destination.url.scheme, "https")
            XCTAssertFalse(destination.title.isEmpty)
            XCTAssertFalse(destination.menuTitle.isEmpty)
            XCTAssertFalse(destination.detail.isEmpty)
            XCTAssertFalse(destination.host.isEmpty)
        }
    }
}
