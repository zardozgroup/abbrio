import ConfigStore
import Foundation
public import SnippetModel

// Espanso's options in `config/default.yml`, as the Settings window shows and changes them.
extension AppModel {
    /// False when there is no `default.yml` to write to, or it can't be read.
    public var canChangeEngineOptions: Bool {
        guard let file = defaultConfig else { return false }
        return file.problem == nil
    }

    /// The value `default.yml` sets for an option. Nil means the file leaves it to Espanso.
    public func writtenValue(of option: EngineOption) -> EngineOptionValue? {
        guard let file = defaultConfig else { return nil }
        return option.value(scalar: file.values[option.key], list: file.lists[option.key])
    }

    /// True when the file has the key, even with a value the app can't show.
    public func isWritten(_ option: EngineOption) -> Bool {
        defaultConfig?.keys.contains(option.key) ?? false
    }

    /// The value to show: the one in the file, or Espanso's default.
    public func shownValue(of option: EngineOption) -> EngineOptionValue? {
        writtenValue(of: option) ?? option.defaultValue
    }

    /// Writes an option, or with nil removes its line so that Espanso's default applies again.
    @discardableResult
    public func setEngineOption(_ option: EngineOption, to value: EngineOptionValue?) -> Bool {
        guard let path = defaultConfig?.path else { return false }
        // Showing a default must not write it: only a value that differs from what is there is saved.
        if let value, writtenValue(of: option) == value { return true }
        if value == nil, !isWritten(option) { return true }
        return changeDefaultConfig { editor throws(EditError) in
            switch value {
            case .bool(let flag)?: try editor.setOption(option.key, .bool(flag), in: path)
            case .integer(let number)?: try editor.setOption(option.key, .integer(number), in: path)
            case .string(let text)?:
                // Fixed words such as `auto` and `OFF` are written bare, as Espanso's own files have them.
                if case .choice = option.kind {
                    try editor.setOption(option.key, .word(text), in: path)
                } else {
                    try editor.setOption(option.key, .string(text), in: path)
                }
            case .list(let items)?: try editor.setList(option.key, items, in: path)
            case nil:
                if case .tokens = option.kind {
                    try editor.setList(option.key, nil, in: path)
                } else {
                    try editor.setOption(option.key, nil, in: path)
                }
            }
        }
    }

    /// Whether `default.yml` switches statistics on. Nil when the file says nothing, which means off.
    public var statisticsSetting: Bool? { defaultConfig?.statsEnabled }

    public var statisticsAreOn: Bool { statisticsSetting == true }

    public var supportsStatistics: Bool { engineVersion?.supportsStatistics ?? true }

    /// Switches statistics on or off, or with nil removes the setting.
    @discardableResult
    public func setStatistics(_ isOn: Bool?) -> Bool {
        guard let path = defaultConfig?.path else { return false }
        if isOn == statisticsSetting { return true }
        return changeDefaultConfig { editor throws(EditError) in
            try editor.setStatsEnabled(isOn, in: path)
        }
    }

    /// True once, for the main window that opens at launch, when the preference says not to show it.
    public func takeLaunchWindowDismissal() -> Bool {
        guard !hasHandledLaunchWindow else { return false }
        hasHandledLaunchWindow = true
        return !preferences.showsMainWindowAtLaunch && !wasReopened
    }

    /// The app was opened again from the Dock or the Finder while it was running.
    public func handleReopen(hasVisibleWindows: Bool) {
        wasReopened = true
        if !hasVisibleWindows { showMainWindow() }
    }

    /// The lines of `default.yml` that hold options of one tab, as they are in the file.
    public func writtenLines(in tab: EngineOption.Tab) -> [String] {
        guard let file = defaultConfig else { return [] }
        return EngineOption.options(in: tab).compactMap { option in
            guard file.keys.contains(option.key) else { return nil }
            if let list = file.lists[option.key] { return "\(option.key): \(list.count) \(list.count == 1 ? "entry" : "entries")" }
            return "\(option.key): \(file.values[option.key] ?? "…")"
        }
    }
}
