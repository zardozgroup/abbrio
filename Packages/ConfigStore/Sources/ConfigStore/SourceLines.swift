import Foundation
import SnippetModel

/// The text of a file split into lines, for working out which lines a match occupies.
struct SourceLines {
    /// Line contents without their line endings. Index 0 is line 1.
    let lines: [Substring]

    init(_ text: String) {
        // Swift treats "\r\n" as a single character, so both line endings are named here.
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        self.lines = lines
    }

    var count: Int { lines.count }

    func line(_ number: Int) -> Substring {
        lines[number - 1]
    }

    func text(in range: LineRange) -> String {
        guard range.first >= 1, range.last <= count, range.first <= range.last else { return "" }
        return lines[(range.first - 1)...(range.last - 1)].joined(separator: "\n")
    }

    /// Number of leading spaces.
    func indentation(ofLine number: Int) -> Int {
        line(number).prefix { $0 == " " }.count
    }

    func isBlank(_ number: Int) -> Bool {
        line(number).allSatisfy { $0 == " " || $0 == "\t" }
    }

    func isComment(_ number: Int) -> Bool {
        line(number).drop { $0 == " " || $0 == "\t" }.first == "#"
    }

    /// True when the line's first non-space character is the dash of a sequence item.
    func isDashLine(_ number: Int) -> Bool {
        let content = line(number).drop { $0 == " " }
        guard content.first == "-" else { return false }
        let rest = content.dropFirst()
        return rest.isEmpty || rest.first == " "
    }

    /// The line holding the dash of the item whose first node starts at the given position.
    ///
    /// Yams reports where an item's content starts. That is the dash line for a block or flow item, but a later
    /// line when the dash is followed by an anchor or stands alone.
    func dashLine(forNodeAtLine nodeLine: Int, column: Int) -> Int? {
        var number = min(nodeLine, count)
        while number >= 1 {
            if isDashLine(number), indentation(ofLine: number) < column {
                return number
            }
            number -= 1
        }
        return nil
    }

    /// Moves `last` back over trailing blank and comment lines, never past `first`.
    func trimmingTrailingBlanksAndComments(first: Int, last: Int) -> Int {
        var end = last
        while end > first, isBlank(end) || isComment(end) {
            end -= 1
        }
        return end
    }

    /// The first line of the unbroken run of comment lines directly above a dash line, at the dash's indentation
    /// or deeper. Returns nil when there is none.
    func leadingCommentStart(aboveDashLine dashLine: Int) -> Int? {
        let indent = indentation(ofLine: dashLine)
        var number = dashLine - 1
        var start: Int?
        while number >= 1, isComment(number), indentation(ofLine: number) >= indent {
            start = number
            number -= 1
        }
        return start
    }
}
