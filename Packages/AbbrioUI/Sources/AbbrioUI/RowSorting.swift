import CoreFoundation
import Foundation

nonisolated extension Array where Element == SnippetRow {
    /// Sorts the rows the way `sort(using:)` does, with a fast path for the table's own column comparators.
    ///
    /// `sort(using:)` reads each key through its key path and converts the current locale on every
    /// comparison, which takes over a second for a set of 75,000 items. The fast path reads every key once
    /// and compares with the options `localizedStandardCompare` uses, against one copy of the locale.
    /// Any comparator other than a column's standard string comparator falls back to `sort(using:)`.
    mutating func sortRows(using order: [KeyPathComparator<SnippetRow>]) {
        guard count > 1, !order.isEmpty else { return }
        var columns: [(keys: [CFString], ascending: Bool)] = []
        for comparator in order {
            guard let keyPath = Self.textColumns.first(where: {
                comparator == KeyPathComparator($0, order: comparator.order)
            }) else {
                sort(using: order)
                return
            }
            columns.append((map { Self.nativeString($0[keyPath: keyPath]) }, comparator.order == .forward))
        }

        let locale = CFLocaleCopyCurrent()
        let options: CFStringCompareFlags = [
            .compareCaseInsensitive, .compareNumerically, .compareWidthInsensitive, .compareForcedOrdering,
        ]
        var positions = Array<Int>(indices)
        positions.sort { a, b in
            for column in columns {
                let left = column.keys[a]
                let result = CFStringCompareWithOptionsAndLocale(
                    left, column.keys[b], CFRange(location: 0, length: CFStringGetLength(left)), options, locale
                )
                if result == .compareEqualTo { continue }
                return (result == .compareLessThan) == column.ascending
            }
            // Equal on every column: keep the original order, as the stable `sort(using:)` does.
            return a < b
        }
        self = positions.map { self[$0] }
    }

    /// A CoreFoundation copy of the text. Comparing bridged Swift strings reads their characters through
    /// Objective-C calls on every comparison; native copies are read directly.
    private static func nativeString(_ text: String) -> CFString {
        let characters = [UInt16](text.utf16)
        return CFStringCreateWithCharacters(nil, characters, characters.count)
    }

    /// The text fields a column can sort by. A comparator on one of these with the standard string comparison
    /// takes the fast path.
    private static let textColumns: [any KeyPath<SnippetRow, String> & Sendable] = [
        \.abbreviation, \.expansion, \.description, \.setName,
    ]
}
