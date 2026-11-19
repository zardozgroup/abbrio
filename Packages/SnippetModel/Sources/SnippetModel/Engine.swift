import Foundation

/// The version of the installed Espanso, as printed by `espanso --version`.
public struct EngineVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads the first `x.y.z` found in the text, so both `2.4.1` and `espanso 2.4.1` work.
    public init?(parsing text: String) {
        let pattern = /(\d+)\.(\d+)\.(\d+)/
        guard let match = text.firstMatch(of: pattern),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// The app needs Espanso 2.x.
    public var isSupported: Bool { major == 2 }

    public var supportsStatistics: Bool { self >= EngineVersion(major: 2, minor: 4, patch: 0) }
    public var supportsListSeparator: Bool { self >= EngineVersion(major: 2, minor: 4, patch: 0) }
    public var supportsDateTimeZone: Bool { self >= EngineVersion(major: 2, minor: 3, patch: 0) }
    public var supportsYAMLExtension: Bool { self >= EngineVersion(major: 2, minor: 3, patch: 0) }
}

/// What the status pill in the toolbar shows.
public enum EngineStatus: Hashable, Sendable {
    case running
    case paused
    case secureInput
    case notRunning
    /// No `espanso` binary was found.
    case notInstalled
}
