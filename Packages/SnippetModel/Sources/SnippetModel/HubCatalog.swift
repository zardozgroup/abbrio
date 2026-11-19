public import Foundation

/// A version such as `1.2.0`, compared number by number.
public struct PackageVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var parts: [Int]

    /// Nil when the text is not numbers separated by dots.
    public init?(_ text: String) {
        let fields = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        var parts: [Int] = []
        for field in fields {
            guard let number = Int(field), number >= 0 else { return nil }
            parts.append(number)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: PackageVersion, rhs: PackageVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: PackageVersion, rhs: PackageVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var parts = parts
        while parts.last == 0 { parts.removeLast() }
        hasher.combine(parts)
    }

    /// True when `candidate` is a later version than `installed`. Text that is not a version never is.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let candidate = PackageVersion(candidate), let installed = PackageVersion(installed) else { return false }
        return candidate > installed
    }
}

/// One published version of a package in the Hub's index.
public struct HubPackage: Identifiable, Hashable, Sendable, Codable {
    public var name: String
    public var author: String
    public var description: String
    public var title: String
    public var version: String
    public var tags: [String]
    public var archiveURL: String
    public var archiveChecksumURL: String

    public var id: String { name + "@" + version }

    enum CodingKeys: String, CodingKey {
        case name, author, description, title, version, tags
        case archiveURL = "archive_url"
        case archiveChecksumURL = "archive_sha256_url"
    }

    public init(
        name: String, author: String = "", description: String = "", title: String = "", version: String = "0.1.0",
        tags: [String] = [], archiveURL: String = "", archiveChecksumURL: String = ""
    ) {
        self.name = name
        self.author = author
        self.description = description
        self.title = title
        self.version = version
        self.tags = tags
        self.archiveURL = archiveURL
        self.archiveChecksumURL = archiveChecksumURL
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        author = (try? values.decodeIfPresent(String.self, forKey: .author)) ?? ""
        description = (try? values.decodeIfPresent(String.self, forKey: .description)) ?? ""
        title = (try? values.decodeIfPresent(String.self, forKey: .title)) ?? ""
        tags = (try? values.decodeIfPresent([String].self, forKey: .tags)) ?? []
        archiveURL = (try? values.decodeIfPresent(String.self, forKey: .archiveURL)) ?? ""
        archiveChecksumURL = (try? values.decodeIfPresent(String.self, forKey: .archiveChecksumURL)) ?? ""
    }

    /// The title, or the name when the index gives no title.
    public var displayTitle: String { title.isEmpty ? name : title }

    /// The package's page on the Hub website.
    public var hubPage: URL? { HubIndex.page(forPackageNamed: name) }
}

/// The Hub's list of packages.
public struct HubIndex: Equatable, Sendable {
    /// When the Hub last rebuilt the index.
    public var lastUpdate: Date?
    /// Every published version, as the index lists them.
    public var entries: [HubPackage]

    public static let empty = HubIndex(entries: [])
    public static let website = URL(string: "https://hub.espanso.org")!

    public static func page(forPackageNamed name: String) -> URL? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://hub.espanso.org/" + encoded)
    }

    public init(lastUpdate: Date? = nil, entries: [HubPackage]) {
        self.lastUpdate = lastUpdate
        self.entries = entries
    }

    /// Reads `package_index.json`. Throws when the file has another shape.
    public init(data: Data) throws {
        struct File: Decodable {
            var last_update: Double?
            var packages: [HubPackage]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        lastUpdate = file.last_update.map { Date(timeIntervalSince1970: $0) }
        entries = file.packages
    }

    /// The versions of one package, newest first.
    public func versions(of name: String) -> [HubPackage] {
        entries.filter { $0.name == name }.sorted { lhs, rhs in
            switch (PackageVersion(lhs.version), PackageVersion(rhs.version)) {
            case let (left?, right?): return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.version > rhs.version
            }
        }
    }

    public func latest(_ name: String) -> HubPackage? {
        versions(of: name).first
    }

    /// Each package once, at its newest version, in the index's order.
    public var packages: [HubPackage] {
        var seen: Set<String> = []
        var result: [HubPackage] = []
        for entry in entries where seen.insert(entry.name).inserted {
            if let latest = latest(entry.name) { result.append(latest) }
        }
        return result
    }

    /// How many packages carry each tag, most used first. A package counts once whatever its versions say.
    public var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for package in packages {
            for tag in Set(package.tags.map { $0.lowercased() }) where !tag.isEmpty {
                counts[tag, default: 0] += 1
            }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// The packages that pass a filter: featured ones first, then by title.
    public func results(
        search: String = "", tag: String? = nil, featuredOnly: Bool = false, featured: Set<String> = []
    ) -> [HubPackage] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return packages.filter { package in
            if featuredOnly, !featured.contains(package.name) { return false }
            if let tag, !package.tags.contains(where: { $0.lowercased() == tag }) { return false }
            guard !words.isEmpty else { return true }
            let text = ([package.title, package.name, package.description, package.author] + package.tags)
                .joined(separator: "\n").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        .sorted { lhs, rhs in
            let left = featured.contains(lhs.name), right = featured.contains(rhs.name)
            if left != right { return left }
            let order = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
        }
    }
}

/// The packages the Hub website shows as featured. The index does not say; the website keeps a list of names.
public enum FeaturedPackages {
    /// The list as it stood on 2026-11-11, used until a newer one has been fetched.
    public static let shipped = [
        "all-emojis", "html-utils-package", "lorem", "spanish-accent", "greek-letters-improved", "math-symbols",
        "medical-docs", "shruggie", "espanso-dice",
    ]

    /// Where the website keeps its list.
    public static let source = URL(string: "https://raw.githubusercontent.com/espanso/hub-frontend/main/app/model/packages.ts")!

    /// Reads the names out of the website's source file. Nil when the list is not where it used to be, or
    /// holds anything but plain package names.
    public static func names(inSource text: String) -> [String]? {
        // The declaration, not a later use of the name: an equals sign follows closely, then the list.
        guard let marker = text.range(of: "featuredPackages"),
              let equals = text[marker.upperBound...].firstIndex(of: "="),
              text.distance(from: marker.upperBound, to: equals) < 40,
              let open = text[equals...].firstIndex(of: "["),
              text[text.index(after: equals)..<open].allSatisfy(\.isWhitespace),
              let close = text[open...].firstIndex(of: "]")
        else { return nil }
        var names: [String] = []
        for piece in text[text.index(after: open)..<close].split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count >= 2, let quote = trimmed.first, quote == "\"" || quote == "'", trimmed.last == quote else {
                return nil
            }
            let name = String(trimmed.dropFirst().dropLast())
            let isPlain = !name.isEmpty && name.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
            }
            guard isPlain else { return nil }
            names.append(name)
        }
        return names.isEmpty || names.count > 200 ? nil : names
    }
}

/// What an installed package's `_manifest.yml` and `_pkgsource.yml` say.
public struct PackageInfo: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case hub
        /// Installed from a git repository, with its address.
        case git(String)
        case unknown
    }

    public var name: String
    public var title: String
    public var description: String
    public var version: String
    public var author: String
    public var tags: [String]
    public var homepage: String
    public var source: Source

    public init(
        name: String, title: String = "", description: String = "", version: String = "", author: String = "",
        tags: [String] = [], homepage: String = "", source: Source = .unknown
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.version = version
        self.author = author
        self.tags = tags
        self.homepage = homepage
        self.source = source
    }

    /// Reads `_pkgsource.yml`: the word `hub`, or a `!git` entry with the repository's address.
    public static func source(fromFileText text: String) -> Source {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { return .unknown }
        if first == "hub" || first == "!hub" { return .hub }
        guard first.hasPrefix("!git") else { return .unknown }
        for line in lines where line.hasPrefix("repo_url:") {
            var value = line.dropFirst("repo_url:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            return .git(value)
        }
        return .git("")
    }
}
