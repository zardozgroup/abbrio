public import Foundation

/// Finds the `espanso` binary.
///
/// The order is: the user's own choice, each folder in `PATH`, the two Homebrew locations, and the binary
/// inside `Espanso.app`. An app started from the Finder gets a short `PATH`, which is why the fixed locations
/// are checked as well.
public struct EspansoLocator: Sendable {
    public static let fixedLocations = [
        "/opt/homebrew/bin/espanso",
        "/usr/local/bin/espanso",
        "/Applications/Espanso.app/Contents/MacOS/espanso",
    ]

    /// A binary the user picked in Settings.
    public var override: URL?
    /// The value of the `PATH` environment variable.
    public var searchPath: String
    public var isExecutable: @Sendable (String) -> Bool

    public init(
        override: URL? = nil,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    ) {
        self.override = override
        self.searchPath = searchPath
        self.isExecutable = isExecutable
    }

    /// Every place that is checked, in order, without duplicates.
    public var candidates: [String] {
        var result: [String] = []
        func add(_ path: String) {
            if !result.contains(path) { result.append(path) }
        }
        if let override { add(override.path) }
        for folder in searchPath.split(separator: ":") where !folder.isEmpty {
            add((String(folder) as NSString).appendingPathComponent("espanso"))
        }
        Self.fixedLocations.forEach(add)
        return result
    }

    public func locate() -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}
