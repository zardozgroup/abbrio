import XCTest
@testable import SnippetModel

final class HubCatalogTests: XCTestCase {
    private let json = """
    {"last_update": 1700000000, "packages": [
      {"name": "dice", "author": "Ann", "description": "Rolls dice", "title": "Dice Roller", "version": "0.1.0",
       "tags": ["fun", "Utility"], "archive_url": "https://example.invalid/dice-0.1.0.zip", "archive_sha256_url": "https://example.invalid/dice-0.1.0-sha256.txt"},
      {"name": "dice", "author": "Ann", "description": "Rolls dice", "title": "Dice Roller", "version": "0.10.0",
       "tags": ["fun", "utility"], "archive_url": "a", "archive_sha256_url": "b"},
      {"name": "dice", "author": "Ann", "description": "Rolls dice", "title": "Dice Roller", "version": "0.2.0",
       "tags": ["fun"], "archive_url": "a", "archive_sha256_url": "b"},
      {"name": "accents", "author": "Bo", "description": "Accented letters", "title": "accents", "version": "1.0.0",
       "tags": ["languages"], "archive_url": "a", "archive_sha256_url": "b"},
      {"name": "zeta", "author": "Cy", "description": "Greek letters for maths", "title": "Zeta", "version": "2.0.0",
       "tags": ["languages", "math"], "archive_url": "a", "archive_sha256_url": "b"}
    ]}
    """

    private func index() throws -> HubIndex { try HubIndex(data: Data(json.utf8)) }

    func testVersionsCompareByNumber() {
        XCTAssertTrue(PackageVersion.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertFalse(PackageVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(PackageVersion.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertFalse(PackageVersion.isNewer("latest", than: "1.0.0"))
        XCTAssertNil(PackageVersion("1..2"))
        XCTAssertEqual(PackageVersion("1.2.0"), PackageVersion("1.2"))
    }

    func testEachPackageIsListedOnceAtItsNewestVersion() throws {
        let index = try index()
        XCTAssertEqual(index.lastUpdate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(index.packages.map(\.name), ["dice", "accents", "zeta"])
        XCTAssertEqual(index.latest("dice")?.version, "0.10.0")
        XCTAssertEqual(index.versions(of: "dice").map(\.version), ["0.10.0", "0.2.0", "0.1.0"])
        XCTAssertNil(index.latest("nothing"))
    }

    func testTagsAreCountedOncePerPackage() throws {
        let counts = try index().tagCounts
        XCTAssertEqual(counts.map(\.tag), ["languages", "fun", "math", "utility"])
        XCTAssertEqual(counts.map(\.count), [2, 1, 1, 1])
    }

    func testResultsAreFilteredAndPutFeaturedFirst() throws {
        let index = try index()
        XCTAssertEqual(index.results(featured: ["zeta"]).map(\.name), ["zeta", "accents", "dice"])
        XCTAssertEqual(index.results(search: "LETTERS").map(\.name), ["accents", "zeta"])
        XCTAssertEqual(index.results(search: "ann dice").map(\.name), ["dice"])
        XCTAssertEqual(index.results(tag: "languages").map(\.name), ["accents", "zeta"])
        XCTAssertEqual(index.results(featuredOnly: true, featured: ["zeta"]).map(\.name), ["zeta"])
        XCTAssertEqual(index.results(search: "nothing here"), [])
    }

    func testAnIndexOfAnotherShapeIsRefused() {
        XCTAssertThrowsError(try HubIndex(data: Data("{\"packages\": 3}".utf8)))
        XCTAssertThrowsError(try HubIndex(data: Data("<html>".utf8)))
    }

    func testFeaturedNamesAreReadFromTheWebsiteSource() {
        let source = "import x;\nexport const featuredPackages: string[] = [\n  \"all-emojis\",\n  'lorem',\n];\nexport function isFeatured() { return featuredPackages.includes(1); }\n"
        XCTAssertEqual(FeaturedPackages.names(inSource: source), ["all-emojis", "lorem"])
        XCTAssertNil(FeaturedPackages.names(inSource: "export const other = [\"a\"];"))
        XCTAssertNil(FeaturedPackages.names(inSource: "export const featuredPackages = [load(), \"a\"];"))
        XCTAssertNil(FeaturedPackages.names(inSource: "export const featuredPackages = [\"<script>\"];"))
        XCTAssertNil(FeaturedPackages.names(inSource: "export const featuredPackages = [];"))
        XCTAssertEqual(FeaturedPackages.shipped.count, 9)
    }

    func testThePackageSourceFileIsRead() {
        XCTAssertEqual(PackageInfo.source(fromFileText: "hub\n"), .hub)
        XCTAssertEqual(
            PackageInfo.source(fromFileText: "!git\nrepo_url: https://example.invalid/a/b\nrepo_branch: null\nuse_native_git: false\n"),
            .git("https://example.invalid/a/b")
        )
        XCTAssertEqual(PackageInfo.source(fromFileText: ""), .unknown)
    }
}
