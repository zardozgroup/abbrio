public import Foundation
public import ConfigStore
public import SnippetModel

/// How a set stands in one application compared with all other applications.
public nonisolated enum AppSetState: Equatable, Sendable {
    case same(isOn: Bool)
    /// On in this application, off elsewhere: the app's config lists the file under `extra_includes`.
    case onHere
    /// Off in this application, on elsewhere: the app's config lists it under `extra_excludes`.
    case offHere

    public var isOn: Bool {
        switch self {
        case .same(let isOn): return isOn
        case .onHere: return true
        case .offHere: return false
        }
    }
}

/// Another config file whose filter also applies to an application.
public nonisolated struct AppOverlap: Identifiable, Equatable, Sendable {
    public var path: String
    /// False when the app can't tell whether the file applies.
    public var isCertain: Bool
    /// True when Espanso would use that file, which sorts first, and ignore the one being shown.
    public var wins: Bool

    public var id: String { path }
}

/// The per-application side of the model: one config file per listed application.
extension AppModel {
    /// The options that can be set per application, with what Espanso uses when nothing is set.
    public nonisolated static let appOptionKeys = ["backend", "inject_delay", "key_delay", "paste_shortcut", "clipboard_threshold"]

    /// `config/default.yml`, which applies to all other applications.
    public var defaultConfig: ConfigFile? {
        configFiles.first(where: \.isDefault)
    }

    /// The config files that apply to particular applications, in the order Espanso considers them.
    public var appConfigs: [ConfigFile] {
        configFiles.filter { !$0.isDefault && $0.hasFilter }.sorted { $0.path < $1.path }
    }

    public func appConfig(_ path: String?) -> ConfigFile? {
        guard let path else { return nil }
        return configFiles.first { $0.path == path }
    }

    /// The bundle identifier a config file was made for, when its filter names exactly one.
    public func bundleID(of file: ConfigFile) -> String? {
        file.filterClass.flatMap(AppFilter.bundleID(fromClassPattern:))
    }

    private var appEditor: AppConfigEditor? {
        guard let writer else { return nil }
        if let discard { return AppConfigEditor(writer: writer, discard: discard) }
        return AppConfigEditor(writer: writer)
    }

    private func appSwitch(for set: SnippetSet) -> AppSwitch {
        set.kind == .package ? .package(String(set.id.dropFirst("packages/".count))) : .set(set.id)
    }

    private func isLoaded(_ set: SnippetSet, in file: ConfigFile?) -> Bool {
        let path = set.files.first?.path ?? "match/" + set.id
        return ConfigEvaluator(base: defaultConfig).isLoaded(path, in: file)
    }

    /// How a set stands in the application a config file is for.
    public func state(of set: SnippetSet, inApp path: String) -> AppSetState {
        let here = isLoaded(set, in: appConfig(path))
        let elsewhere = isLoaded(set, in: nil)
        if here == elsewhere { return .same(isOn: here) }
        return here ? .onHere : .offHere
    }

    /// True when a set is loaded in all other applications.
    public func isOnEverywhere(_ set: SnippetSet) -> Bool {
        isLoaded(set, in: nil)
    }

    /// How many sets and options differ from all other applications.
    public func changeCount(inApp path: String) -> Int {
        let differing = sets.filter { state(of: $0, inApp: path) != .same(isOn: isLoaded($0, in: nil)) }.count
        let options = Self.appOptionKeys.filter { appConfig(path)?.values[$0] != nil }.count
        return differing + options
    }

    public func isAllOff(inApp path: String) -> Bool {
        appConfig(path)?.enable == false
    }

    /// Adds an application to the list. When a config file already applies to it, that file is used instead
    /// of writing a competing one. Returns the config file's path.
    @discardableResult
    public func addApp(bundleID: String, bundlePath: String?) -> String? {
        if let existing = appConfigs.first(where: { AppFilter.match($0, bundleID: bundleID, path: bundlePath) == .yes }) {
            return existing.path
        }
        return changeApps { editor throws(EditError) in try editor.addApp(bundleID: bundleID) }
    }

    @discardableResult
    public func removeApp(_ path: String) -> Bool {
        changeApps { editor throws(EditError) in
            try editor.removeApp(configPath: path)
            return path
        } != nil
    }

    @discardableResult
    public func setOn(_ isOn: Bool, _ set: SnippetSet, inApp path: String) -> Bool {
        let item = appSwitch(for: set)
        let base = defaultConfig
        return changeApps { editor throws(EditError) in
            try editor.setLoaded(isOn, item, in: path, base: base)
            return path
        } != nil
    }

    @discardableResult
    public func setAllOff(_ isOff: Bool, inApp path: String) -> Bool {
        changeApps { editor throws(EditError) in
            try editor.setAllOff(isOff, in: path)
            return path
        } != nil
    }

    /// Sets one option for an application. Nil goes back to the value from `default.yml`.
    @discardableResult
    public func setOption(_ key: String, _ value: ConfigValue?, inApp path: String) -> Bool {
        changeApps { editor throws(EditError) in
            try editor.setOption(key, value, in: path)
            return path
        } != nil
    }

    /// The value all other applications use for an option, when `default.yml` sets one.
    public func inheritedOption(_ key: String) -> String? {
        defaultConfig?.values[key]
    }

    /// The text of a config file as it is on disk.
    public func configText(_ path: String) -> String {
        guard let data = try? writer?.read(path) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Other config files whose filters also apply to the application a file is for.
    ///
    /// Espanso uses only one application config at a time: the first that matches, in file-name order.
    public func overlaps(forApp path: String, bundlePath: String?) -> [AppOverlap]? {
        guard let file = appConfig(path), let bundleID = bundleID(of: file) else { return nil }
        var result: [AppOverlap] = []
        for other in appConfigs where other.path != path {
            switch AppFilter.match(other, bundleID: bundleID, path: bundlePath) {
            case .no: continue
            case .yes: result.append(AppOverlap(path: other.path, isCertain: true, wins: other.path < path))
            case .maybe: result.append(AppOverlap(path: other.path, isCertain: false, wins: false))
            }
        }
        return result
    }

    // MARK: Abbrio's own windows

    /// The config file that applies to Abbrio's own windows.
    public var ownAppConfig: ConfigFile? {
        guard let ownBundleID else { return nil }
        return appConfigs.first { AppFilter.match($0, bundleID: ownBundleID, path: nil) == .yes }
    }

    /// False when Espanso is switched off in Abbrio's own windows, so that a trigger typed into one of its
    /// fields stays as typed.
    public var expandsInOwnWindows: Bool {
        !ConfigEvaluator(base: defaultConfig).isDisabled(in: ownAppConfig)
    }

    /// True when the app can write the config file for its own windows.
    public var canSetExpandsInOwnWindows: Bool {
        ownBundleID != nil && writer != nil
    }

    @discardableResult
    public func setExpandsInOwnWindows(_ expands: Bool) -> Bool {
        guard let ownBundleID else { return false }
        if let file = ownAppConfig {
            return setAllOff(!expands, inApp: file.path)
        }
        guard !expands else { return true }
        return changeApps { editor throws(EditError) in try editor.addApp(bundleID: ownBundleID, allOff: true) } != nil
    }

    /// Writes the config file that switches Espanso off in Abbrio's own windows, unless a config file for
    /// Abbrio is already there. Whoever wants expansions here switches them on in Settings, which keeps the
    /// file, so it is not written again.
    func keepExpansionsOutOfOwnWindows() {
        guard let ownBundleID, let appEditor, configFolder != nil, ownAppConfig == nil else { return }
        // Nothing is reported when this fails: the folder may be read-only, and the app works without it.
        guard (try? appEditor.addApp(bundleID: ownBundleID, allOff: true)) != nil else { return }
        reloadNow()
    }

    /// Changes `config/default.yml` and reads the folder again. Returns false, with an alert, on failure.
    func changeDefaultConfig(_ operation: (AppConfigEditor) throws(EditError) -> Void) -> Bool {
        changeApps { editor throws(EditError) in
            try operation(editor)
            return ""
        } != nil
    }

    private func changeApps(_ operation: (AppConfigEditor) throws(EditError) -> String) -> String? {
        guard let appEditor else { return nil }
        do {
            let path = try operation(appEditor)
            reloadNow()
            return path
        } catch {
            reloadNow()
            alertMessage = error.message
            return nil
        }
    }
}
