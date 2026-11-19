public import Foundation

/// Checks a package archive before anything is read from it, from the listing `zipinfo -T -s` prints.
///
/// Nothing is unpacked to disk: the preview reads single entries with `unzip -p`. The checks keep a hostile
/// archive from costing more than a few megabytes: too many entries, too much declared data, links,
/// encrypted entries, names that would act as patterns or leave the archive, and duplicate names.
public enum PackageArchive {
    public struct Entry: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case file
            case folder
        }

        public var name: String
        public var size: Int64
        public var kind: Kind

        public init(name: String, size: Int64, kind: Kind) {
            self.name = name
            self.size = size
            self.kind = kind
        }
    }

    public struct Refusal: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }

        init(_ message: String) {
            self.message = message
        }
    }

    public static let entryLimit = 2_000
    /// The most all entries together may hold once unpacked, as the archive declares it.
    public static let totalLimit: Int64 = 32 * 1024 * 1024
    /// The most a single README or match file may hold.
    public static let fileLimit = 4 * 1024 * 1024
    /// How many files the preview reads at most.
    public static let readLimit = 100

    /// True for a file name the preview reads items from.
    public static func isMatchFile(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        return !fileName.hasPrefix("_") && !fileName.hasPrefix(".")
            && (lowercased.hasSuffix(".yml") || lowercased.hasSuffix(".yaml"))
    }

    /// Reads the listing and refuses an archive the preview should not open.
    public static func entries(fromListing listing: String) throws(Refusal) -> [Entry] {
        var declaredCount: Int?
        var entries: [Entry] = []
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("Zip file size:"), let range = line.range(of: "number of entries:") {
                declaredCount = Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let entry = try entry(fromLine: String(line)) else { continue }
            entries.append(entry)
            guard entries.count <= entryLimit else { throw Refusal("The archive holds too many files.") }
        }
        // Every entry must have been understood; a name that broke the listing would show up here.
        guard let declaredCount, declaredCount == entries.count else {
            throw Refusal("The archive's list of files could not be read.")
        }
        guard entries.reduce(Int64(0), { $0 + $1.size }) <= totalLimit else {
            throw Refusal("The archive would unpack to more than 32 MB.")
        }
        var seen: Set<String> = []
        for entry in entries {
            let key = entry.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(key).inserted else { throw Refusal("The archive holds two files with the same name.") }
        }
        return entries
    }

    /// One line of `zipinfo -T -s` output: permissions, version, system, size, flags, method, date and the name.
    /// Lines that are not entries give nil.
    static func entry(fromLine line: String) throws(Refusal) -> Entry? {
        var rest = Substring(line)
        var fields: [Substring] = []
        for _ in 0..<7 {
            rest = rest.drop(while: { $0 == " " })
            guard let end = rest.firstIndex(of: " ") else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        guard let size = Int64(fields[3]), fields[4].count == 2, fields[6].contains("."),
              let kindMark = fields[0].first, rest.first == " "
        else { return nil }
        let name = String(rest.dropFirst())

        if fields[4].first?.isUppercase == true { throw Refusal("The archive holds encrypted files.") }
        let kind: Entry.Kind
        switch kindMark {
        case "-": kind = name.hasSuffix("/") ? .folder : .file
        case "d": kind = .folder
        case "l": throw Refusal("The archive holds links.")
        default: throw Refusal("The archive holds something other than files and folders.")
        }
        guard isSafeName(name) else { throw Refusal("The archive holds a file with an unsafe name.") }
        return Entry(name: name, size: size, kind: kind)
    }

    /// A name that stays inside the archive and that `unzip` reads literally: relative, no `..`, no
    /// backslash, no control characters and none of the characters `unzip` treats as a pattern.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("-") else { return false }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || "\\*?[]".unicodeScalars.contains($0) }) {
            return false
        }
        return !name.split(separator: "/").contains("..")
    }

    /// The entries the preview reads: READMEs and match files, outside hidden folders, at most `readLimit`.
    /// Files over `fileLimit` are left out and reported as unreadable.
    public static func entriesToRead(_ entries: [Entry]) -> (read: [Entry], skipped: Bool) {
        var read: [Entry] = []
        var skipped = false
        for entry in entries.sorted(by: { $0.name < $1.name }) where entry.kind == .file {
            let parts = entry.name.split(separator: "/")
            guard let fileName = parts.last.map(String.init),
                  !parts.dropLast().contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" })
            else { continue }
            guard fileName.lowercased() == "readme.md" || isMatchFile(fileName) else { continue }
            guard entry.size <= Int64(fileLimit), read.count < readLimit else {
                skipped = true
                continue
            }
            read.append(entry)
        }
        return (read, skipped)
    }
}
