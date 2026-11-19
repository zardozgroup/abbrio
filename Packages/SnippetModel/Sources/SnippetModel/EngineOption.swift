import Foundation

/// A value of one of Espanso's options in `config/default.yml`.
public enum EngineOptionValue: Hashable, Sendable {
    case bool(Bool)
    case integer(Int)
    case string(String)
    case list([String])
}

/// One of Espanso's options that the Settings window can change.
public struct EngineOption: Identifiable, Hashable, Sendable {
    public enum Tab: String, CaseIterable, Sendable {
        case expansion
        case espansoUI
        case timing
    }

    public enum Kind: Hashable, Sendable {
        case toggle(default: Bool)
        /// A whole number. A nil default means Espanso picks the value itself.
        case number(default: Int?, unit: String, range: ClosedRange<Int>)
        /// One of a fixed list of values, written as given.
        case choice(values: [String], default: String)
        /// Free text. A nil default means Espanso picks the value itself.
        case text(default: String?)
        /// A list of short strings.
        case tokens(default: [String])
    }

    /// The key in the YAML file.
    public var key: String
    public var title: String
    /// A line of explanation under the title, when the title alone could mislead.
    public var note: String?
    public var tab: Tab
    public var kind: Kind
    /// The first Espanso version that knows the option.
    public var minimumVersion: EngineVersion?

    public var id: String { key }

    public init(
        _ key: String, _ title: String, tab: Tab, _ kind: Kind, note: String? = nil,
        minimumVersion: EngineVersion? = nil
    ) {
        self.key = key
        self.title = title
        self.note = note
        self.tab = tab
        self.kind = kind
        self.minimumVersion = minimumVersion
    }

    /// The value Espanso uses when the file doesn't set the option, when that is a fixed value.
    public var defaultValue: EngineOptionValue? {
        switch kind {
        case .toggle(let value): return .bool(value)
        case .number(let value, _, _): return value.map { .integer($0) }
        case .choice(_, let value): return .string(value)
        case .text(let value): return value.map { .string($0) }
        case .tokens(let value): return .list(value)
        }
    }

    /// Reads the option's value from what a config file holds. Nil when the file doesn't set it, or sets
    /// something this kind of option can't show.
    public func value(scalar: String?, list: [String]?) -> EngineOptionValue? {
        switch kind {
        case .toggle:
            switch scalar?.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return nil
            }
        case .number:
            return scalar.flatMap { Int($0) }.map { .integer($0) }
        case .choice(let values, _):
            guard let scalar else { return nil }
            // Espanso reads these without regard to case; the list's own spelling is shown.
            return .string(values.first { $0.caseInsensitiveCompare(scalar) == .orderedSame } ?? scalar)
        case .text:
            return scalar.map { .string($0) }
        case .tokens:
            return list.map { .list($0) }
        }
    }

    /// True when the installed Espanso knows the option. An unknown version is given the benefit of the doubt.
    public func isAvailable(in version: EngineVersion?) -> Bool {
        guard let minimumVersion, let version else { return true }
        return version >= minimumVersion
    }

    public static func options(in tab: Tab) -> [EngineOption] {
        all.filter { $0.tab == tab }
    }

    public static func option(_ key: String) -> EngineOption? {
        all.first { $0.key == key }
    }

    /// The names Espanso accepts for the key that switches expansions on and off.
    public static let toggleKeys = [
        "OFF", "CTRL", "ALT", "SHIFT", "META",
        "LEFT_CTRL", "LEFT_ALT", "LEFT_SHIFT", "LEFT_META",
        "RIGHT_CTRL", "RIGHT_ALT", "RIGHT_SHIFT", "RIGHT_META",
    ]

    /// The characters that end a word, as Espanso has them when the file says nothing.
    public static let defaultWordSeparators = [
        " ", ",", ".", "?", "!", "\r", "\n", "\t", "'", "\"", "\u{0C}",
        "(", ")", "[", "]", "{", "}", "<", ">", ":", ";", "\u{A0}",
    ]

    public static let all: [EngineOption] = [
        EngineOption("backend", "Backend", tab: .expansion, .choice(values: ["auto", "inject", "clipboard"], default: "auto"),
                     note: "How the expansion gets into the app: typed, pasted, or whichever suits its length."),
        EngineOption("clipboard_threshold", "Clipboard threshold", tab: .expansion,
                     .number(default: 100, unit: "characters", range: 0...100_000),
                     note: "With the automatic backend, longer expansions are pasted."),
        EngineOption("preserve_clipboard", "Preserve clipboard", tab: .expansion, .toggle(default: true)),
        EngineOption("undo_backspace", "Undo expansion with Backspace", tab: .expansion, .toggle(default: true)),
        EngineOption("backspace_limit", "Backspace limit", tab: .expansion, .number(default: 5, unit: "keys", range: 0...100)),
        EngineOption("auto_restart", "Restart Espanso when files change", tab: .expansion, .toggle(default: true)),
        EngineOption("word_separators", "Word separators", tab: .expansion, .tokens(default: defaultWordSeparators)),
        EngineOption("toggle_key", "Toggle key", tab: .expansion, .choice(values: toggleKeys, default: "OFF"),
                     note: "Pressed twice, it switches expansions off and on."),

        EngineOption("search_shortcut", "Search bar shortcut", tab: .espansoUI, .text(default: "ALT+SPACE"),
                     note: "Opens Espanso's own search bar. Write off to disable it."),
        EngineOption("search_trigger", "Search bar trigger", tab: .espansoUI, .text(default: "off"),
                     note: "Typing this opens Espanso's own search bar. Write off to disable it."),
        EngineOption("show_icon", "Show Espanso's menu bar icon", tab: .espansoUI, .toggle(default: true)),
        EngineOption("show_notifications", "Show notifications", tab: .espansoUI, .toggle(default: true)),
        EngineOption("max_form_width", "Largest form width", tab: .espansoUI, .number(default: 700, unit: "pixels", range: 100...10_000)),
        EngineOption("max_form_height", "Largest form height", tab: .espansoUI, .number(default: 500, unit: "pixels", range: 100...10_000)),

        EngineOption("inject_delay", "Delay between injected events", tab: .timing, .number(default: nil, unit: "ms", range: 0...10_000)),
        EngineOption("key_delay", "Delay between key presses", tab: .timing, .number(default: nil, unit: "ms", range: 0...10_000)),
        EngineOption("pre_paste_delay", "Wait before pasting", tab: .timing, .number(default: 300, unit: "ms", range: 0...10_000)),
        EngineOption("restore_clipboard_delay", "Wait before restoring the clipboard", tab: .timing,
                     .number(default: 300, unit: "ms", range: 0...10_000)),
        EngineOption("paste_shortcut", "Paste shortcut", tab: .timing, .text(default: nil),
                     note: "The keys Espanso presses to paste, such as CMD+V."),
        EngineOption("paste_shortcut_event_delay", "Delay between paste shortcut keys", tab: .timing,
                     .number(default: 10, unit: "ms", range: 0...10_000)),
        EngineOption("post_form_delay", "Wait after a form closes", tab: .timing, .number(default: 200, unit: "ms", range: 0...10_000)),
        EngineOption("post_search_delay", "Wait after the search bar closes", tab: .timing,
                     .number(default: 200, unit: "ms", range: 0...10_000)),
        EngineOption("max_regex_buffer_size", "Longest regular expression match", tab: .timing,
                     .number(default: 30, unit: "characters", range: 1...10_000),
                     minimumVersion: EngineVersion(major: 2, minor: 3, patch: 0)),
    ]

    /// How a separator is shown in the list of tokens: invisible characters get a name.
    public static func tokenName(_ token: String) -> String {
        switch token {
        case " ": return "space"
        case "\r": return "return"
        case "\n": return "newline"
        case "\t": return "tab"
        case "\u{0C}": return "form feed"
        case "\u{A0}": return "no-break space"
        default: return token
        }
    }
}
