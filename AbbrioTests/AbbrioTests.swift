import XCTest
@testable import Abbrio

final class AbbrioTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.zardozgroup.abbrio")
    }

    func testAppIconIsBundled() {
        XCTAssertNotNil(NSImage(named: "AppIcon"))
    }

    func testAppIsNotSandboxed() {
        XCTAssertNil(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"])
    }
}
