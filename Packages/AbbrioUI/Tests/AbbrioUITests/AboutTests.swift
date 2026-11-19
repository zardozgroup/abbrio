import XCTest
@testable import AbbrioUI

final class AboutTests: XCTestCase {
    func testEveryEntryShipsItsLicenseText() throws {
        for item in Acknowledgement.all {
            let text = try XCTUnwrap(item.licenseText, item.name)
            if item.license.hasPrefix("MIT") {
                XCTAssertTrue(text.contains("Permission is hereby granted"), item.name)
            } else if item.license.hasPrefix("Apache-2.0") {
                XCTAssertTrue(text.contains("Apache License"), item.name)
                XCTAssertTrue(text.contains("Version 2.0"), item.name)
            } else {
                XCTFail("\(item.name) has a license the test does not know: \(item.license)")
            }
        }
        let systemLicense = try XCTUnwrap(Acknowledgement.all.first { $0.name == "swift-system" }?.licenseText)
        XCTAssertTrue(systemLicense.contains("Runtime Library Exception"))
    }

    /// The window and `docs/dependencies.md` list the same packages, versions, licenses and purposes.
    func testEntriesMatchTheDependencyList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AbbrioUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AbbrioUI
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent()
        let document = try String(contentsOf: root.appendingPathComponent("docs/dependencies.md"), encoding: .utf8)

        struct Entry: Equatable { var name, url, version, license, usedBy, purpose: String }
        let rows = document.split(separator: "\n").map(String.init).filter { $0.hasPrefix("| [") }
        let listed = try rows.map { row -> Entry in
            let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(cells.count, 5, row)
            let link = try XCTUnwrap(cells[0].wholeMatch(of: /\[(.+)\]\((.+)\)/), row)
            return Entry(
                name: String(link.1), url: String(link.2), version: cells[1], license: cells[2],
                usedBy: cells[3].replacingOccurrences(of: "`", with: ""), purpose: cells[4]
            )
        }
        let shown = Acknowledgement.all.filter { $0.usedBy != "Yams" }.map {
            Entry(name: $0.name, url: $0.url.absoluteString, version: $0.version, license: $0.license,
                  usedBy: $0.usedBy, purpose: $0.purpose.replacingOccurrences(of: "`", with: ""))
        }
        XCTAssertEqual(listed.map(\.name).sorted(), shown.map(\.name).sorted())
        for entry in shown {
            let row = listed.first { $0.name == entry.name }
            XCTAssertEqual(row.map { Entry(name: $0.name, url: $0.url, version: $0.version, license: $0.license,
                                           usedBy: $0.usedBy, purpose: $0.purpose.replacingOccurrences(of: "`", with: "")) },
                           entry)
        }

        // Code bundled inside a package is named in the text under the table.
        for item in Acknowledgement.all where item.usedBy == "Yams" {
            XCTAssertTrue(document.contains("Yams bundles \(item.name), which is also \(item.license) licensed."), item.name)
        }
    }

    func testVersionText() {
        XCTAssertEqual(AboutView.versionText(info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "2"]),
                       "Version 1.0.0 (2)")
        XCTAssertEqual(AboutView.versionText(info: ["CFBundleShortVersionString": "1.0.0"]), "Version 1.0.0")
        XCTAssertEqual(AboutView.versionText(info: nil), "Version ?")
    }
}
