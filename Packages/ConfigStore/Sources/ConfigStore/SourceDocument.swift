import Foundation

/// The bytes of a file as lines, so that some lines can be replaced while every other byte stays as it is.
struct SourceDocument {
    /// Line contents without their line endings. Index 0 is line 1.
    private(set) var lines: [String]
    /// The line ending that followed each line: "\n", "\r\n", or "" for a last line without one.
    private(set) var endings: [String]
    /// The line ending used for new lines.
    let newline: String
    private let hasByteOrderMark: Bool

    init(_ data: Data) throws(EditError) {
        guard var text = String(data: data, encoding: .utf8) else {
            throw .notEditable("The file is not UTF-8 text.")
        }
        // Decoding may or may not keep the mark, so the bytes decide.
        hasByteOrderMark = data.starts(with: [0xEF, 0xBB, 0xBF])
        if text.unicodeScalars.first == "\u{FEFF}" {
            text = String(String.UnicodeScalarView(text.unicodeScalars.dropFirst()))
        }

        var lines: [String] = []
        var endings: [String] = []
        var current = String.UnicodeScalarView()
        var windowsEndings = 0
        var previousWasReturn = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasReturn {
                    current.removeLast()
                    endings.append("\r\n")
                    windowsEndings += 1
                } else {
                    endings.append("\n")
                }
                lines.append(String(current))
                current.removeAll()
                previousWasReturn = false
                continue
            }
            if previousWasReturn {
                // YAML counts a lone carriage return as a line break; the app does not write such files.
                throw .notEditable("The file uses old Mac line endings.")
            }
            previousWasReturn = scalar == "\r"
            current.append(scalar)
        }
        if previousWasReturn {
            throw .notEditable("The file uses old Mac line endings.")
        }
        if !current.isEmpty {
            lines.append(String(current))
            endings.append("")
        }
        self.lines = lines
        self.endings = endings
        newline = windowsEndings * 2 > endings.count ? "\r\n" : "\n"
    }

    /// The text without a byte order mark, as the parser reads it.
    var text: String {
        zip(lines, endings).map { $0 + $1 }.joined()
    }

    var data: Data {
        Data(((hasByteOrderMark ? "\u{FEFF}" : "") + text).utf8)
    }

    var count: Int { lines.count }

    func line(_ number: Int) -> String {
        lines[number - 1]
    }

    /// Replaces lines `first...last` (1-based, inclusive) with new lines. An empty range, written as
    /// `first: n, last: n - 1`, inserts before line `n`; `n` may be one past the last line.
    mutating func replace(first: Int, last: Int, with newLines: [String]) {
        let endedWithoutNewline = endings.last == ""
        lines.replaceSubrange((first - 1)..<last, with: newLines)
        endings.replaceSubrange((first - 1)..<last, with: newLines.map { _ in newline })

        // Keep the file's habit of ending, or not ending, with a line break.
        guard let final = endings.indices.last else { return }
        for index in endings.indices.dropLast() where endings[index].isEmpty {
            endings[index] = newline
        }
        if endedWithoutNewline {
            endings[final] = ""
        } else if endings[final].isEmpty {
            endings[final] = newline
        }
    }

    func isBlank(_ number: Int) -> Bool {
        line(number).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

/// Why a change to a file was refused. Nothing is written when one of these is thrown.
public enum EditError: Error, Equatable, Sendable {
    /// The file or the match is written in a way the form can't change safely.
    case notEditable(String)
    /// The draft is incomplete, for example an empty abbreviation.
    case invalidDraft(String)
    /// The text is not valid YAML, or not a match file.
    case invalidYAML(line: Int?, message: String)
    /// The new text did not parse back to what was intended.
    case verificationFailed(String)
    /// The file changed on disk after it was read.
    case changedOnDisk
    /// A file with that name is already there.
    case alreadyExists(String)
    /// The file could not be read or written.
    case fileSystem(String)

    /// The error in words for the user.
    public var message: String {
        switch self {
        case .notEditable(let reason), .invalidDraft(let reason), .verificationFailed(let reason),
             .fileSystem(let reason):
            return reason
        case .invalidYAML(let line, let message):
            if let line { return "Line \(line): \(message)" }
            return message
        case .changedOnDisk:
            return "The file was changed by another program."
        case .alreadyExists(let name):
            return "A file named \(name) already exists."
        }
    }
}
