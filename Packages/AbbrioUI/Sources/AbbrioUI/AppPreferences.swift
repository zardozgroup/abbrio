public import Foundation
public import Observation

/// What the app does when a set is renamed and its file could be renamed with it.
public nonisolated enum RenameFilePolicy: String, CaseIterable, Sendable {
    case ask
    case always
    case never

    public var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// The app's own preferences. None of them touch Espanso's files.
@Observable
public final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public var dockIconVisibilityChanged: ((Bool) -> Void)?

    public var showsDockIcon: Bool {
        didSet {
            defaults.set(showsDockIcon, forKey: "showsDockIcon")
            if !showsDockIcon { showsMenuBarIcon = true }
            dockIconVisibilityChanged?(showsDockIcon)
        }
    }

    public var showsMainWindowAtLaunch: Bool {
        didSet { defaults.set(showsMainWindowAtLaunch, forKey: "showsMainWindowAtLaunch") }
    }
    public var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: "showsMenuBarIcon") }
    }
    /// Words per minute, for the estimate of time saved.
    public var typingSpeed: Int {
        didSet { defaults.set(typingSpeed, forKey: "typingSpeed") }
    }
    /// A path to the `espanso` program to use instead of the one found. Empty means none.
    public var binaryPath: String {
        didSet { defaults.set(binaryPath, forKey: "espansoBinaryPath") }
    }
    public var renameFilePolicy: RenameFilePolicy {
        didSet { defaults.set(renameFilePolicy.rawValue, forKey: "renameFilePolicy") }
    }
    /// Milliseconds between the Quick Search panel closing and the paste.
    public var insertionDelay: Int {
        didSet { defaults.set(insertionDelay, forKey: "quickSearchInsertionDelay") }
    }

    public static let defaultTypingSpeed = 40
    public static let defaultInsertionDelay = 200
    public static let insertionDelayRange = 50...2000
    public static let typingSpeedRange = 5...200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsDockIcon = defaults.object(forKey: "showsDockIcon") as? Bool ?? true
        showsMainWindowAtLaunch = defaults.object(forKey: "showsMainWindowAtLaunch") as? Bool ?? true
        showsMenuBarIcon = defaults.object(forKey: "showsMenuBarIcon") as? Bool ?? true
        let speed = defaults.integer(forKey: "typingSpeed")
        typingSpeed = Self.typingSpeedRange.contains(speed) ? speed : Self.defaultTypingSpeed
        binaryPath = defaults.string(forKey: "espansoBinaryPath") ?? ""
        renameFilePolicy = defaults.string(forKey: "renameFilePolicy").flatMap(RenameFilePolicy.init) ?? .ask
        let delay = defaults.integer(forKey: "quickSearchInsertionDelay")
        insertionDelay = Self.insertionDelayRange.contains(delay) ? delay : Self.defaultInsertionDelay
        if !showsDockIcon { showsMenuBarIcon = true }
    }

    public var binaryURL: URL? {
        let trimmed = binaryPath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }
}
