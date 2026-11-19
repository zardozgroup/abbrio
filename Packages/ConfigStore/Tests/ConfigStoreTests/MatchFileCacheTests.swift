import XCTest
import SnippetModel
@testable import ConfigStore

final class MatchFileCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("match"), withIntermediateDirectories: true)
        try write("match/big.yml", "matches:\n  - trigger: teh\n    replace: the\n  - trigger: adn\n    replace: and\n")
        try write("match/small.yml", "matches:\n  - trigger: ;sig\n    replace: Regards\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testCachedLoadMatchesAnUncachedLoad() throws {
        let sample = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/sample")
        let cache = MatchFileCache()
        let plain = ConfigLoader(root: sample).load()
        let first = ConfigLoader(root: sample, cache: cache).load()
        let second = ConfigLoader(root: sample, cache: cache).load()
        XCTAssertEqual(first.sets, plain.sets)
        XCTAssertEqual(second.sets, plain.sets)
        XCTAssertEqual(second.configFiles, plain.configFiles)
    }

    func testOnlyChangedFilesAreParsedAgain() throws {
        let cache = MatchFileCache()
        let loader = ConfigLoader(root: root, cache: cache)
        _ = loader.load()
        XCTAssertEqual(cache.parseCount, 2)

        _ = loader.load()
        XCTAssertEqual(cache.parseCount, 2, "nothing changed, so nothing is parsed")

        try write("match/small.yml", "matches:\n  - trigger: ;sig\n    replace: Best regards\n")
        let snapshot = loader.load()
        XCTAssertEqual(cache.parseCount, 3, "only the edited file is parsed")
        let small = try XCTUnwrap(snapshot.sets.first { $0.id == "small.yml" })
        XCTAssertEqual(small.snippets.first?.expansion, .text("Best regards"))
        XCTAssertEqual(snapshot.sets.first { $0.id == "big.yml" }?.snippets.count, 2)
    }

    func testRemovedAndRenamedFilesAreNotServedFromTheCache() throws {
        let cache = MatchFileCache()
        let loader = ConfigLoader(root: root, cache: cache)
        _ = loader.load()
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("match/small.yml"), to: root.appendingPathComponent("match/renamed.yml")
        )
        let snapshot = loader.load()
        XCTAssertEqual(snapshot.sets.map(\.id).sorted(), ["big.yml", "renamed.yml"])
        // The identity of each item includes its file, so a renamed file is parsed again under its new path.
        XCTAssertEqual(
            snapshot.sets.first { $0.id == "renamed.yml" }?.snippets.first?.id.file, "match/renamed.yml"
        )
        XCTAssertEqual(cache.parseCount, 3)
    }

    func testAFileThatFailsIsReportedEveryTime() throws {
        let cache = MatchFileCache()
        let loader = ConfigLoader(root: root, cache: cache)
        try write("match/small.yml", "matches: [unclosed\n")
        for _ in 0..<2 {
            let small = loader.load().sets.first { $0.id == "small.yml" }
            XCTAssertEqual(small?.problems.first?.severity, .unreadable)
        }
        try write("match/small.yml", "matches:\n  - trigger: ok\n    replace: fixed\n")
        XCTAssertEqual(loader.load().sets.first { $0.id == "small.yml" }?.problems, [])
    }
}
