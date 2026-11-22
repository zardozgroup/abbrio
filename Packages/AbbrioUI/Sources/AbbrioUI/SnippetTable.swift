import AppKit
import SwiftUI
import SnippetModel

/// The abbreviation list, drawn by an `NSTableView`.
///
/// SwiftUI's `Table` keeps state for every row and adds or removes rows one by one, which takes seconds for
/// a set of 75,000 items. An `NSTableView` asks its data source only for the rows on screen, so showing,
/// leaving and sorting a set cost about the same whatever its size.
struct SnippetTable: NSViewRepresentable {
    /// Where the table writes back: selection, header clicks, the context menu and Delete.
    let model: AppModel
    // What the table shows. These are read in the parent's `body`, so every change gives SwiftUI a new value
    // and it calls `updateNSView`. Reading the model inside `updateNSView` isn't tracked reliably.
    let rows: [SnippetRow]
    let selection: Snippet.ID?
    let sortOrder: [KeyPathComparator<SnippetRow>]

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(for: context.coordinator)
    }

    /// Builds the table and its scroll view, wired to the coordinator.
    static func makeScrollView(for coordinator: Coordinator) -> NSScrollView {
        let table = ListTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .custom
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Abbreviations")

        for column in ListColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.minWidth = column.widths.min
            tableColumn.width = column.widths.ideal
            tableColumn.maxWidth = column.widths.max
            if column.keyPath != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            table.addTableColumn(tableColumn)
        }

        table.dataSource = coordinator
        table.delegate = coordinator
        // Rows can be dragged onto a set in the sidebar.
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        table.onDelete = { [weak coordinator] in coordinator?.deleteSelectedItem() }

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        coordinator.table = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.update(rows: rows, selection: selection, sortOrder: sortOrder)
    }

    // MARK: Columns

    nonisolated enum ListColumn: String, CaseIterable {
        case abbreviation, expansion, description, options

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .abbreviation: return "Abbreviation"
            case .expansion: return "Expansion"
            case .description: return "Description"
            case .options: return "Options"
            }
        }

        var widths: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
            switch self {
            case .abbreviation: return (80, 110, 10_000)
            case .expansion: return (120, 200, 10_000)
            case .description: return (80, 130, 10_000)
            case .options: return (64, 76, 110)
            }
        }

        /// The field the column sorts by. The Options column doesn't sort.
        var keyPath: (any KeyPath<SnippetRow, String> & Sendable)? {
            switch self {
            case .abbreviation: return \SnippetRow.abbreviation
            case .expansion: return \SnippetRow.expansion
            case .description: return \SnippetRow.description
            case .options: return nil
            }
        }

        /// The model's comparators as the table's sort descriptors, so the header shows the sort.
        static func sortDescriptors(for order: [KeyPathComparator<SnippetRow>]) -> [NSSortDescriptor] {
            order.compactMap { comparator in
                guard let column = allCases.first(where: { $0.keyPath.map { $0 == comparator.keyPath } ?? false })
                else { return nil }
                return NSSortDescriptor(key: column.rawValue, ascending: comparator.order == .forward)
            }
        }

        /// The table's sort descriptors, after a click on a header, as the model's comparators.
        static func comparators(for descriptors: [NSSortDescriptor]) -> [KeyPathComparator<SnippetRow>] {
            descriptors.compactMap { descriptor in
                guard let key = descriptor.key, let keyPath = ListColumn(rawValue: key)?.keyPath else { return nil }
                return KeyPathComparator(keyPath, order: descriptor.ascending ? .forward : .reverse)
            }
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: AppModel
        weak var table: ListTableView?
        private(set) var rows: [SnippetRow] = []
        /// Where each item is in `rows`, so a selection is found without a scan.
        private var positions: [Snippet.ID: Int] = [:]
        /// True while the table is being brought in line with the model, so its callbacks don't write back.
        private var isUpdating = false

        init(model: AppModel) {
            self.model = model
        }

        func update(rows newRows: [SnippetRow], selection: Snippet.ID?, sortOrder: [KeyPathComparator<SnippetRow>]) {
            guard let table else { return }
            isUpdating = true
            defer { isUpdating = false }

            let descriptors = ListColumn.sortDescriptors(for: sortOrder)
            if table.sortDescriptors != descriptors {
                table.sortDescriptors = descriptors
            }
            // The model hands back the same array while nothing changed, so this is usually a pointer check.
            if newRows != rows {
                rows = newRows
                var positions: [Snippet.ID: Int] = [:]
                positions.reserveCapacity(newRows.count)
                for (index, row) in newRows.enumerated() where positions[row.id] == nil {
                    positions[row.id] = index
                }
                self.positions = positions
                table.reloadData()
            }
            let wanted = selection.flatMap { positions[$0] } ?? -1
            if table.selectedRow != wanted {
                if wanted >= 0 {
                    table.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
                    table.scrollRowToVisible(wanted)
                } else {
                    table.deselectAll(nil)
                }
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating else { return }
            let order = ListColumn.comparators(for: tableView.sortDescriptors)
            if !order.isEmpty { model.sortOrder = order }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(ItemDrag.payload(for: rows[row].id), forType: .string)
            return item
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, let column = ListColumn(rawValue: identifier.rawValue),
                  rows.indices.contains(row)
            else { return nil }
            let item = rows[row]
            switch column {
            case .options:
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? GlyphCell
                    ?? GlyphCell(identifier: identifier)
                cell.glyphs = item.glyphs
                return cell
            case .abbreviation, .expansion, .description:
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCell
                    ?? TextCell(column: column)
                switch column {
                case .abbreviation:
                    cell.text = item.abbreviationWithAliases ?? item.abbreviation
                    cell.toolTip = item.abbreviationWithAliases
                case .expansion: cell.text = item.expansion
                default: cell.text = item.description
                }
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            let row = table.selectedRow
            let id = rows.indices.contains(row) ? rows[row].id : nil
            if model.selectedSnippetID != id {
                model.selectedSnippetID = id
            }
        }

        // MARK: Context menu and Delete

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let id = rows[table.clickedRow].id
            let duplicate = NSMenuItem(title: "Duplicate", action: #selector(duplicateItem(_:)), keyEquivalent: "")
            let delete = NSMenuItem(title: "Delete…", action: #selector(deleteItem(_:)), keyEquivalent: "")
            for item in [duplicate, delete] {
                item.target = self
                item.representedObject = id
                menu.addItem(item)
            }
        }

        @objc private func duplicateItem(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? Snippet.ID else { return }
            model.selectedSnippetID = id
            model.duplicateSelectedItem()
        }

        @objc private func deleteItem(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? Snippet.ID else { return }
            model.selectedSnippetID = id
            model.requestItemDeletion()
        }

        func deleteSelectedItem() {
            guard model.selectedSnippetID != nil else { return }
            model.requestItemDeletion()
        }
    }
}

/// The list's table view: the Delete key and Edit > Delete ask to delete the selected item.
final class ListTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .delete || event.specialKey == .deleteForward, selectedRow >= 0 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func delete(_ sender: Any?) {
        onDelete?()
    }
}

/// A one-line text cell. The abbreviation is monospaced and the description is secondary, as on the boards.
private final class TextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(column: SnippetTable.ListColumn) {
        super.init(frame: .zero)
        identifier = column.identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        switch column {
        case .abbreviation:
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .description:
            label.textColor = .secondaryLabelColor
        default:
            break
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The Options column: the glyphs drawn by `OptionGlyphView`, right-aligned. Only visible rows have one.
private final class GlyphCell: NSTableCellView {
    private let host = NSHostingView(rootView: GlyphRow(glyphs: []))

    var glyphs: [OptionGlyph] {
        get { host.rootView.glyphs }
        set { if newValue != host.rootView.glyphs { host.rootView = GlyphRow(glyphs: newValue) } }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private struct GlyphRow: View {
    var glyphs: [OptionGlyph]

    var body: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            ForEach(glyphs, id: \.self) { glyph in
                OptionGlyphView(glyph: glyph)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
