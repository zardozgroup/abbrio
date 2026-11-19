import XCTest
import SnippetModel
@testable import ConfigStore

/// Changes to Espanso's options in `config/default.yml`.
final class SettingsTests: XCTestCase {
    private let original = """
    # Settings for every application.
    toggle_key: OFF   # switched off on purpose

    # The search bar
    search_shortcut: ALT+SPACE
    show_notifications: false
    """ + "\n"

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func parse(_ text: String) -> ConfigFile {
        ConfigFileParser.parse(text, path: "config/default.yml", url: URL(fileURLWithPath: "/default.yml"))
    }

    func testAChangedOptionIsTheOnlyLineWritten() throws {
        let data = Data(original.utf8)
        let changed = try ConfigFileEditor.setValue("backspace_limit", .integer(3), in: data)
        XCTAssertEqual(text(changed), original + "backspace_limit: 3\n")
        // Every key the user never touched is absent from the file.
        let keys = parse(text(changed)).keys
        XCTAssertEqual(keys, ["toggle_key", "search_shortcut", "show_notifications", "backspace_limit"])
        for option in EngineOption.all where !keys.contains(option.key) {
            XCTAssertFalse(text(changed).contains(option.key + ":"), option.key)
        }
    }

    func testResetRemovesTheKeyAndLeavesTheRestByteForByte() throws {
        let data = Data(original.utf8)
        let changed = try ConfigFileEditor.setValue("backspace_limit", .integer(3), in: data)
        let reset = try ConfigFileEditor.setValue("backspace_limit", nil, in: changed)
        XCTAssertEqual(text(reset), original)
        // Resetting a key the file never had changes nothing.
        XCTAssertEqual(try ConfigFileEditor.setValue("undo_backspace", nil, in: data), data)
    }

    func testAnExistingOptionIsChangedInPlace() throws {
        let changed = try ConfigFileEditor.setValue("show_notifications", .bool(true), in: Data(original.utf8))
        XCTAssertEqual(text(changed), original.replacingOccurrences(of: "show_notifications: false", with: "show_notifications: true"))
    }

    func testWordSeparatorsAreWrittenReadablyAndReadBack() throws {
        let separators = EngineOption.defaultWordSeparators
        let changed = try ConfigFileEditor.setList("word_separators", separators, in: Data(original.utf8))
        let written = text(changed)
        XCTAssertTrue(written.hasPrefix(original))
        XCTAssertTrue(written.contains(#"  - "\r""#))
        XCTAssertTrue(written.contains(#"  - "\x0c""#))
        XCTAssertTrue(written.contains(#"  - "\xa0""#))
        XCTAssertTrue(written.contains(#"  - "\"""#))
        XCTAssertEqual(parse(written).lists["word_separators"], separators)
        let reset = try ConfigFileEditor.setList("word_separators", nil, in: changed)
        XCTAssertEqual(text(reset), original)
    }

    func testStatisticsAreSwitchedOnAndOff() throws {
        let data = Data(original.utf8)
        XCTAssertNil(parse(original).statsEnabled)
        let on = try ConfigFileEditor.setStatsEnabled(true, in: data)
        XCTAssertEqual(text(on), original + "stats:\n  enabled: true\n")
        XCTAssertEqual(parse(text(on)).statsEnabled, true)
        let off = try ConfigFileEditor.setStatsEnabled(false, in: on)
        XCTAssertEqual(text(off), original + "stats:\n  enabled: false\n")
        XCTAssertEqual(text(try ConfigFileEditor.setStatsEnabled(nil, in: off)), original)
    }

    func testOtherStatisticsLinesAreKept() throws {
        let file = "stats:\n    # kept\n    retention_days: 90\n    enabled: false\nbackend: clipboard\n"
        let on = try ConfigFileEditor.setStatsEnabled(true, in: Data(file.utf8))
        XCTAssertEqual(text(on), "stats:\n    # kept\n    retention_days: 90\n    enabled: true\nbackend: clipboard\n")
        let removed = try ConfigFileEditor.setStatsEnabled(nil, in: on)
        XCTAssertEqual(text(removed), "stats:\n    # kept\n    retention_days: 90\nbackend: clipboard\n")
        let added = try ConfigFileEditor.setStatsEnabled(true, in: removed)
        XCTAssertEqual(text(added), "stats:\n    enabled: true\n    # kept\n    retention_days: 90\nbackend: clipboard\n")
    }

    func testStatisticsOnOneLineAreRewrittenOnlyWhenNothingElseIsThere() throws {
        let simple = try ConfigFileEditor.setStatsEnabled(false, in: Data("stats: {enabled: true}\n".utf8))
        XCTAssertEqual(text(simple), "stats:\n  enabled: false\n")
        XCTAssertThrowsError(try ConfigFileEditor.setStatsEnabled(false, in: Data("stats: {enabled: true, other: 1}\n".utf8)))
    }

    func testOptionValuesAreReadByKind() throws {
        let file = parse("backend: Clipboard\nundo_backspace: false\nbackspace_limit: 3\npaste_shortcut: CMD+V\nclipboard_threshold: many\n")
        func value(_ key: String) -> EngineOptionValue? {
            EngineOption.option(key)?.value(scalar: file.values[key], list: file.lists[key])
        }
        XCTAssertEqual(value("backend"), .string("clipboard"))
        XCTAssertEqual(value("undo_backspace"), .bool(false))
        XCTAssertEqual(value("backspace_limit"), .integer(3))
        XCTAssertEqual(value("paste_shortcut"), .string("CMD+V"))
        XCTAssertNil(value("clipboard_threshold"))
        XCTAssertNil(value("preserve_clipboard"))
        XCTAssertEqual(EngineOption.option("backspace_limit")?.defaultValue, .integer(5))
        XCTAssertNil(EngineOption.option("inject_delay")?.defaultValue)
    }
}
