import XCTest
import SnippetModel
@testable import ConfigStore

final class YAMLLimitTests: XCTestCase {
    private func aliasTree(depth: Int) -> String {
        var yaml = "a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n"
        for level in 1...depth {
            yaml += "a\(level): &a\(level) [" + Array(repeating: "*a\(level - 1)", count: 10).joined(separator: ", ") + "]\n"
        }
        return yaml + "matches:\n  - trigger: \":x\"\n    replace: \"{{v}}\"\n    vars:\n      - name: v\n        type: echo\n        params:\n          echo: *a\(depth)\n"
    }

    func testAliasesThatExpandTooFarAreRefusedQuickly() {
        // Nine levels of ten stand for ten billion nodes in a few hundred bytes.
        let start = ContinuousClock.now
        XCTAssertThrowsError(try MatchFileParser.parse(aliasTree(depth: 9), path: "bomb.yml")) {
            XCTAssertEqual(($0 as? MatchFileError)?.message, "The file uses YAML aliases that expand to more than Abbrio reads.")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testOrdinaryAliasesStillWork() throws {
        let yaml = """
        defaults: &shared
          word: true
        matches:
          - trigger: ":a"
            replace: one
            <<: *shared
          - trigger: ":b"
            replace: two
            vars:
              - name: list
                type: choice
                params:
                  values: &values [red, green]
              - name: again
                type: choice
                params:
                  values: *values

        """
        let parsed = try MatchFileParser.parse(yaml, path: "ok.yml")
        XCTAssertEqual(parsed.snippets.count, 2)
        XCTAssertEqual(parsed.snippets[1].variables.count, 2)
    }

    func testOversizedAndSpecialFilesAreNotRead() throws {
        let config = try TemporaryConfig(files: ["match/ok.yml": "matches:\n  - trigger: \":a\"\n    replace: one\n"])
        let big = config.root.appendingPathComponent("match/big.yml")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ConfigLoader.fileSizeLimit + 1))
        try handle.close()
        XCTAssertEqual(mkfifo(config.root.appendingPathComponent("match/pipe.yml").path, 0o600), 0)

        let sets = ConfigLoader(root: config.root).load().sets
        XCTAssertEqual(sets.first { $0.id == "ok.yml" }?.snippets.count, 1)
        XCTAssertTrue(sets.first { $0.id == "big.yml" }?.isBroken ?? true)
        XCTAssertTrue(sets.first { $0.id == "pipe.yml" }?.isBroken ?? true)
    }
}
