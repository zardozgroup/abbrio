import XCTest
import AppKit
import SwiftUI
import ConfigStore
import EspansoCLI
import SnippetModel
@testable import AbbrioUI

private struct NoRunner: CommandRunner {
    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        throw CommandError.launchFailed("not available in tests")
    }
}

@MainActor
final class SnippetTableTests: XCTestCase {
    private var root: URL!
    private var model: AppModel!
    private var coordinator: SnippetTable.Coordinator!
    private var scrollView: NSScrollView!
    private var table: ListTableView { coordinator.table! }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-tests-" + UUID().uuidString)
        let match = root.appendingPathComponent("match")
        try FileManager.default.createDirectory(at: match, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        try "toggle_key: OFF\n".write(to: root.appendingPathComponent("config/default.yml"), atomically: true, encoding: .utf8)
        try """
        matches:
          - trigger: item10
            replace: ten
          - trigger: item9
            replace: nine
            label: Number nine
          - trigger: teh
            replace: the
            word: true

        """.write(to: match.appendingPathComponent("work.yml"), atomically: true, encoding: .utf8)
        try """
        matches:
          - trigger: adn
            replace: and

        """.write(to: match.appendingPathComponent("autocorrect.yml"), atomically: true, encoding: .utf8)

        model = AppModel(
            environment: AppEnvironment(configFolderOverride: root, fallbackConfigFolders: []),
            runner: NoRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in false })
        )
        await model.load()
        model.selectedSetID = "work.yml"
        coordinator = SnippetTable.Coordinator(model: model)
        scrollView = SnippetTable.makeScrollView(for: coordinator)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        sync()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// What `updateNSView` does when the model changes.
    private func sync() {
        coordinator.update(rows: model.rows, selection: model.selectedSnippetID, sortOrder: model.sortOrder)
        scrollView.layoutSubtreeIfNeeded()
    }

    private func cell(row: Int, column: SnippetTable.ListColumn) -> NSTableCellView? {
        let index = table.column(withIdentifier: column.identifier)
        return table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    private func text(row: Int, column: SnippetTable.ListColumn) -> String? {
        cell(row: row, column: column)?.textField?.stringValue
    }

    func testShowsTheRowsInTheModelsOrder() {
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual((0..<3).compactMap { text(row: $0, column: .abbreviation) }, ["item9", "item10", "teh"])
        XCTAssertEqual(text(row: 0, column: .expansion), "nine")
        XCTAssertEqual(text(row: 0, column: .description), "Number nine")
        XCTAssertEqual(table.tableColumns.map(\.title), ["Abbreviation", "Expansion", "Description", "Options"])
    }

    func testShowsAllTriggersInOneRowAndFollowsAliasEdits() throws {
        try """
        matches:
          - triggers: [accomodate, acommodate]
            replace: accommodate
            word: true
            propagate_case: true

        """.write(to: root.appendingPathComponent("match/autocorrect.yml"), atomically: true, encoding: .utf8)
        model.reloadNow()
        model.selectedSetID = "autocorrect.yml"
        sync()

        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(text(row: 0, column: .abbreviation), "accomodate, acommodate")
        XCTAssertEqual(cell(row: 0, column: .abbreviation)?.toolTip, "accomodate, acommodate")
        XCTAssertEqual(text(row: 0, column: .expansion), "accommodate")
        let id = try XCTUnwrap(model.selectedSnippetID)

        model.searchText = "acommodate"
        sync()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(model.selectedSnippetID, id)
        XCTAssertEqual(text(row: 0, column: .abbreviation), "accomodate, acommodate")

        model.searchText = ""
        model.updateTriggers { $0.aliases.append("accomadate") }
        XCTAssertTrue(model.commitDraft())
        sync()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(text(row: 0, column: .abbreviation), "accomodate, acommodate, accomadate")

        model.updateTriggers { $0.aliases.removeAll() }
        XCTAssertTrue(model.commitDraft())
        sync()
        XCTAssertEqual(text(row: 0, column: .abbreviation), "accomodate")
        XCTAssertNil(cell(row: 0, column: .abbreviation)?.toolTip)
        XCTAssertEqual(model.selectedSnippetID, id)
    }

    func testCaseNotesFoldOnlyCaseVariantsAndKeepAffixesInTheTable() throws {
        try """
        matches:
          - triggers: [';btw!', ';Btw!', ';BTW!', ';bytw!', ';Bytw!', ';BYTW!']
            replace: by the way
          - triggers: [';sig!', ';Sig!', ';SIG!']
            replace: See you soon

        """.write(to: root.appendingPathComponent("match/work.yml"), atomically: true, encoding: .utf8)
        model.reloadNow()
        let set = try XCTUnwrap(model.selectedSet)
        var info = set.info
        info.prefix = ";"
        info.suffix = "!"
        XCTAssertNil(model.applySetInfo(info, name: set.name, to: set.id, adoptingAffixes: true))
        sync()
        XCTAssertEqual(text(row: 0, column: .abbreviation), ";btw!, ;Btw!, ;BTW!, ;bytw!, ;Bytw!, ;BYTW!")
        XCTAssertEqual(text(row: 1, column: .abbreviation), ";sig!, ;Sig!, ;SIG!")

        model.updateSidecar { notes in
            notes.setCaseInsensitive(true, for: "btw", in: set.id)
            notes.setCaseInsensitive(true, for: "sig", in: set.id)
        }
        sync()
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(text(row: 0, column: .abbreviation), ";btw!, ;bytw!")
        XCTAssertEqual(text(row: 1, column: .abbreviation), ";sig!")
        XCTAssertNil(cell(row: 1, column: .abbreviation)?.toolTip)
    }

    func testSelectionFollowsTheModelAndTheTable() {
        XCTAssertEqual(table.selectedRow, 0, "the first item is selected when a set opens")
        model.selectedSnippetID = model.rows[2].id
        sync()
        XCTAssertEqual(table.selectedRow, 2)

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(model.selectedSnippet?.abbreviation, "item10")

        model.selectedSetID = "autocorrect.yml"
        sync()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(text(row: 0, column: .abbreviation), "adn")
        XCTAssertEqual(table.selectedRow, 0)
    }

    func testHeaderClickSortsTheModelAndTheModelSortShowsInTheHeader() {
        table.sortDescriptors = [NSSortDescriptor(key: "abbreviation", ascending: false)]
        XCTAssertEqual(model.sortOrder, [KeyPathComparator(\SnippetRow.abbreviation, order: .reverse)])
        sync()
        XCTAssertEqual((0..<3).compactMap { text(row: $0, column: .abbreviation) }, ["teh", "item10", "item9"])

        model.sortOrder = [KeyPathComparator(\SnippetRow.expansion)]
        sync()
        XCTAssertEqual(table.sortDescriptors.first?.key, "expansion")
        XCTAssertEqual(table.sortDescriptors.first?.ascending, true)
        XCTAssertEqual(model.sortOrder, [KeyPathComparator(\SnippetRow.expansion)], "showing the sort doesn't write back")
    }

    func testSortMappingRoundTrips() {
        let order = [KeyPathComparator(\SnippetRow.description, order: .reverse), KeyPathComparator(\SnippetRow.abbreviation)]
        let descriptors = SnippetTable.ListColumn.sortDescriptors(for: order)
        XCTAssertEqual(descriptors.map(\.key), ["description", "abbreviation"])
        XCTAssertEqual(SnippetTable.ListColumn.comparators(for: descriptors), order)
    }

    func testDragCarriesTheItemForTheSidebar() throws {
        let writer = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let payload = try XCTUnwrap(writer.string(forType: .string))
        XCTAssertEqual(ItemDrag.id(from: payload), model.rows[0].id)
    }

    func testDeleteKeyAsksForConfirmation() {
        model.selectedSnippetID = model.rows[1].id
        sync()
        table.delete(nil)
        XCTAssertTrue(model.isConfirmingItemDeletion)
        XCTAssertEqual(model.selectedSnippet?.abbreviation, "item10")
    }

    func testContextMenuIsEmptyAwayFromARow() {
        let menu = try! XCTUnwrap(table.menu)
        coordinator.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.isEmpty, "no row was clicked")
    }

    /// Hosts the real list view, as the main window does, and lets SwiftUI process pending updates.
    private func hostedTable() -> (window: NSWindow, table: () -> ListTableView?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SnippetListView(model: model))
        func find(in view: NSView) -> ListTableView? {
            if let table = view as? ListTableView { return table }
            return view.subviews.lazy.compactMap(find(in:)).first
        }
        return (window, { find(in: window.contentView!) })
    }

    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func firstAbbreviation(_ table: ListTableView) -> String? {
        let column = table.column(withIdentifier: SnippetTable.ListColumn.abbreviation.identifier)
        return (table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    func testHostedTableFollowsTheModelThroughSetChangesReloadsAndSorting() throws {
        let (window, table) = hostedTable()
        defer { window.close() }
        settle(window)
        var shown = try XCTUnwrap(table())
        XCTAssertEqual(shown.numberOfRows, 3)
        XCTAssertEqual(firstAbbreviation(shown), "item9")

        for _ in 0..<3 {
            model.selectedSetID = "autocorrect.yml"
            settle(window)
            shown = try XCTUnwrap(table())
            XCTAssertEqual(shown.numberOfRows, 1)
            XCTAssertEqual(firstAbbreviation(shown), "adn")

            // A reload like the ones Undo, Redo and the on/off checkbox cause.
            model.reloadNow()
            model.selectedSetID = "work.yml"
            settle(window)
            shown = try XCTUnwrap(table())
            XCTAssertEqual(shown.numberOfRows, 3)
            XCTAssertEqual(firstAbbreviation(shown), "item9")
        }

        model.sortOrder = [KeyPathComparator(\SnippetRow.abbreviation, order: .reverse)]
        settle(window)
        shown = try XCTUnwrap(table())
        XCTAssertEqual(firstAbbreviation(shown), "teh")
        XCTAssertEqual(shown.sortDescriptors.first?.ascending, false)
    }

    func testHostedTableFollowsTheModelAfterSortingUndoAndRedo() throws {
        let (window, table) = hostedTable()
        defer { window.close() }
        settle(window)
        var shown = try XCTUnwrap(table())

        // The steps from the report: sort with a header click, edit and save, Undo, Redo, then switch sets.
        shown.sortDescriptors = [NSSortDescriptor(key: "expansion", ascending: false)]
        settle(window)
        model.selectedSnippetID = model.rows.first { $0.abbreviation == "teh" }?.id
        settle(window)
        model.updateDraft { $0.body = "then" }
        XCTAssertTrue(model.commitDraft())
        settle(window)
        model.undo()
        settle(window)
        model.redo()
        settle(window)

        for _ in 0..<3 {
            model.selectedSetID = "autocorrect.yml"
            settle(window)
            shown = try XCTUnwrap(table())
            XCTAssertEqual(shown.numberOfRows, 1)
            XCTAssertEqual(firstAbbreviation(shown), "adn")
            model.selectedSetID = "work.yml"
            settle(window)
            shown = try XCTUnwrap(table())
            XCTAssertEqual(shown.numberOfRows, 3)
            // Sorted by expansion, last first: "then", "ten", "nine".
            XCTAssertEqual(firstAbbreviation(shown), "teh")
        }
    }

    func testSwitchingBetweenALargeAndASmallListIsQuick() {
        let preview = ExpansionPreview()
        let large = (0..<75_000).map { index in
            SnippetRow(
                snippet: Snippet(id: .init(file: "match/big.yml", index: index), triggers: ["t\(index)"], expansion: .text("x")),
                setName: "Big", isDuplicate: false, preview: preview
            )
        }
        let small = Array(large.prefix(3))
        let order = [KeyPathComparator(\SnippetRow.abbreviation)]
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<3 {
                coordinator.update(rows: large, selection: large[40_000].id, sortOrder: order)
                scrollView.layoutSubtreeIfNeeded()
                coordinator.update(rows: small, selection: nil, sortOrder: order)
                scrollView.layoutSubtreeIfNeeded()
            }
        }
        XCTAssertEqual(table.numberOfRows, 3)
        print("6 switches between 75,000 and 3 rows: \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}
