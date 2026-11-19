import AppKit
import ConfigStore
import KeyboardShortcuts
import ServiceManagement
import SnippetModel
public import SwiftUI

/// The Settings window: the app's own preferences and Espanso's options in `config/default.yml`.
public struct SettingsView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "sun.max") }
            EngineSettings(model: model, tab: .expansion)
                .tabItem { Label("Expansion", systemImage: "keyboard") }
            EngineSettings(model: model, tab: .espansoUI)
                .tabItem { Label("Espanso UI", systemImage: "macwindow") }
            EngineSettings(model: model, tab: .timing)
                .tabItem { Label("Timing", systemImage: "timer") }
            StatisticsSettings(model: model)
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
        }
        .frame(width: 590, height: 620)
        .task { if !model.hasLoaded { await model.load() } }
    }
}

// MARK: Building blocks

/// A rounded group of rows, as on the Settings board.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// One row of a card: a title, an optional line under it, and a control at the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var note: String?
    var isChanged = false
    var showsDivider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isChanged ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(!isChanged)
                    .accessibilityLabel("Changed from default")
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            if showsDivider { Divider().padding(.leading, 20) }
        }
    }
}

private struct SettingsPage<Content: View>: View {
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(20)
            }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A number field that saves when Return is pressed or the field loses the keyboard.
private struct NumberField: View {
    let value: Int?
    let range: ClosedRange<Int>
    var placeholder = ""
    let commit: (Int?) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .focused($isFocused)
            .onAppear { text = value.map(String.init) ?? "" }
            .onChange(of: value) { _, new in if !isFocused { text = new.map(String.init) ?? "" } }
            .onChange(of: isFocused) { _, focused in if !focused { save() } }
            .onSubmit(save)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let number = Int(trimmed) else {
            // Not a number: go back to what was there. An emptied field means "no value".
            if trimmed.isEmpty, value != nil { commit(nil) }
            text = trimmed.isEmpty ? "" : (value.map(String.init) ?? "")
            return
        }
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        text = String(clamped)
        if clamped != value { commit(clamped) }
    }
}

/// A text field that saves when Return is pressed or the field loses the keyboard.
private struct CommitField: View {
    let value: String
    var placeholder = ""
    var width: CGFloat = 150
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .focused($isFocused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !isFocused { text = new } }
            .onChange(of: isFocused) { _, focused in if !focused { save() } }
            .onSubmit(save)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != value { commit(trimmed) }
    }
}

// MARK: General

struct GeneralSettings: View {
    let model: AppModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var isChecking = false

    private var preferences: AppPreferences { model.preferences }

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsPage(footer: "App-only preferences, stored by Abbrio. Nothing on this tab touches Espanso\u{2019}s files.") {
            SettingsCard {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Abbrio").font(.headline)
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Check Again") {
                        isChecking = true
                        Task {
                            await model.load()
                            isChecking = false
                        }
                    }
                    .disabled(isChecking)
                }
                .padding(12)
            }

            SettingsCard {
                SettingsRow(title: "Launch at login", note: loginError) {
                    Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show main window at launch") {
                    Toggle("Show main window at launch", isOn: $preferences.showsMainWindowAtLaunch)
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(
                    title: "Show menu bar icon",
                    note: preferences.showsMenuBarIcon ? nil : "Open Abbrio again from the Dock or the Finder to get its window back.",
                    showsDivider: false
                ) {
                    Toggle("Show menu bar icon", isOn: $preferences.showsMenuBarIcon)
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            Text("Global shortcuts").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Quick Search") {
                    KeyboardShortcuts.Recorder(for: .quickSearch)
                }
                SettingsRow(title: "New Item from Clipboard") {
                    KeyboardShortcuts.Recorder(for: .defineFromClipboard)
                }
                SettingsRow(title: "New Item from Selection", note: "Needs Accessibility permission to read the selection") {
                    KeyboardShortcuts.Recorder(for: .defineFromSelection)
                }
                SettingsRow(
                    title: "Wait before inserting from Quick Search",
                    note: "Time for the other app to take the keyboard back. Raise it if text goes missing.",
                    showsDivider: false
                ) {
                    NumberField(value: preferences.insertionDelay, range: AppPreferences.insertionDelayRange) {
                        preferences.insertionDelay = $0 ?? AppPreferences.defaultInsertionDelay
                    }
                    Text("ms").foregroundStyle(.secondary)
                }
            }

            SettingsCard {
                SettingsRow(title: "Typing speed for time-saved estimates") {
                    NumberField(value: preferences.typingSpeed, range: AppPreferences.typingSpeedRange) {
                        preferences.typingSpeed = $0 ?? AppPreferences.defaultTypingSpeed
                    }
                    Text("wpm").foregroundStyle(.secondary)
                }
                SettingsRow(title: "When a set is renamed, rename its file") {
                    Picker("When a set is renamed, rename its file", selection: $preferences.renameFilePolicy) {
                        ForEach(RenameFilePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(
                    title: "Expand abbreviations in Abbrio\u{2019}s own windows",
                    note: ownWindowsNote
                ) {
                    Toggle("Expand abbreviations in Abbrio\u{2019}s own windows", isOn: Binding(
                        get: { model.expandsInOwnWindows },
                        set: { model.setExpandsInOwnWindows($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!model.canSetExpandsInOwnWindows)
                }
                SettingsRow(title: "espanso binary", note: binaryNote) {
                    if !preferences.binaryPath.isEmpty {
                        Button("Use Found") {
                            preferences.binaryPath = ""
                            Task { await model.load() }
                        }
                    }
                    Button("Override\u{2026}", action: chooseBinary)
                }
                SettingsRow(title: "Config folder", note: folderNote, showsDivider: false) {
                    Button("Reveal in Finder") {
                        if let folder = model.configFolder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    .disabled(model.configFolder == nil)
                }
            }
        }
    }

    private var ownWindowsNote: String {
        let file = model.ownAppConfig?.path ?? "a file in config/"
        return model.expandsInOwnWindows
            ? "On: a trigger typed into one of Abbrio\u{2019}s fields is replaced as you type it."
            : "Off, so triggers and sample text stay as typed. Kept as enable: false in \(file)."
    }

    private var summary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        var parts = [version.isEmpty ? "Abbrio" : "Version \(version)"]
        if let engine = model.engineVersion {
            parts.append("Espanso \(engine) detected")
            if !engine.isSupported {
                parts.append("this version is not supported")
            } else if !engine.supportsStatistics {
                parts.append("statistics need Espanso 2.4.0")
            } else {
                parts.append("all features available")
            }
        } else if model.binary == nil {
            parts.append("Espanso wasn\u{2019}t found")
        } else {
            parts.append("Espanso didn\u{2019}t report its version")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var binaryNote: String {
        guard let binary = model.binary else {
            return preferences.binaryPath.isEmpty ? "Not found" : "\(preferences.binaryPath) \u{00B7} can\u{2019}t be run"
        }
        return "\(binary.path) \u{00B7} \(model.binaryWasChosen ? "chosen here" : "found on this Mac")"
    }

    private var folderNote: String {
        guard let folder = model.configFolder else { return "Not found" }
        let source = model.configFolderIsOverridden ? "set for this run" : "read-only, from espanso path"
        return (folder.path as NSString).abbreviatingWithTildeInPath + " \u{00B7} " + source
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the espanso program."
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.binaryPath = url.path
        Task { await model.load() }
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS refused: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Espanso options

struct EngineSettings: View {
    let model: AppModel
    let tab: EngineOption.Tab

    private var options: [EngineOption] { EngineOption.options(in: tab) }
    private var rows: [EngineOption] {
        options.filter { option in
            if case .tokens = option.kind { return false }
            return true
        }
    }

    var body: some View {
        SettingsPage {
            HStack(spacing: 6) {
                Text("Writes")
                Tag("config/default.yml", .yaml)
                Text("Options you never change are not written, so Espanso\u{2019}s default applies.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            if !model.canChangeEngineOptions {
                Label(
                    model.defaultConfig == nil
                        ? "There is no config/default.yml in the config folder."
                        : "config/default.yml can\u{2019}t be read. Fix it in a text editor first.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }

            SettingsCard {
                ForEach(rows) { option in
                    OptionRow(model: model, option: option, showsDivider: option.id != rows.last?.id)
                }
            }
            .disabled(!model.canChangeEngineOptions)

            ForEach(options.filter { $0.kind.isTokens }) { option in
                SettingsCard { TokenRow(model: model, option: option) }
                    .disabled(!model.canChangeEngineOptions)
            }

            if tab == .timing {
                Text("These are for apps that lose or scramble characters. Most people never need them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            changedLines
        }
    }

    @ViewBuilder
    private var changedLines: some View {
        let lines = model.writtenLines(in: tab)
        SettingsCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(lines.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty {
                        Text("Nothing on this tab is written to the file right now.")
                    } else {
                        Text(lines.count == 1
                            ? "Changed from default. The only line this tab writes right now:"
                            : "Changed from default. The lines this tab writes right now:")
                        ForEach(lines, id: \.self) { line in
                            Text(line).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
                Spacer()
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
    }
}

private extension EngineOption.Kind {
    var isTokens: Bool {
        if case .tokens = self { return true }
        return false
    }
}

private struct OptionRow: View {
    let model: AppModel
    let option: EngineOption
    let showsDivider: Bool

    private var isWritten: Bool { model.isWritten(option) }
    private var isAvailable: Bool { option.isAvailable(in: model.engineVersion) }

    var body: some View {
        SettingsRow(title: option.title, note: note, isChanged: isWritten, showsDivider: showsDivider) {
            Tag(option.key, .yaml).help(option.key)
            control
            if isWritten {
                Button("Reset") { model.setEngineOption(option, to: nil) }
                    .buttonStyle(.link)
                    .help("Remove \(option.key) from the file, so Espanso\u{2019}s default applies")
            }
        }
        .disabled(!isAvailable)
    }

    private var note: String? {
        if !isAvailable, let version = option.minimumVersion { return "Needs Espanso \(version) or later." }
        if isWritten, model.writtenValue(of: option) == nil {
            return "The file holds a value the app can\u{2019}t show. Reset removes it."
        }
        return option.note
    }

    @ViewBuilder
    private var control: some View {
        switch option.kind {
        case .toggle(let fallback):
            Toggle(option.title, isOn: Binding(
                get: {
                    if case .bool(let value)? = model.shownValue(of: option) { return value }
                    return fallback
                },
                set: { model.setEngineOption(option, to: .bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

        case .number(let fallback, let unit, let range):
            NumberField(value: number, range: range, placeholder: fallback == nil ? "auto" : "") { value in
                model.setEngineOption(option, to: value.map { .integer($0) })
            }
            Text(unit).foregroundStyle(.secondary)

        case .choice(let values, let fallback):
            Picker(option.title, selection: Binding(
                get: { string ?? fallback },
                set: { model.setEngineOption(option, to: .string($0)) }
            )) {
                ForEach(choices(values), id: \.self) { value in
                    Text(value == fallback ? "\(Self.title(value)) (default)" : Self.title(value)).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()

        case .text(let fallback):
            CommitField(value: isWritten ? (string ?? "") : "", placeholder: fallback ?? "automatic") { value in
                model.setEngineOption(option, to: value.isEmpty ? nil : .string(value))
            }

        case .tokens:
            EmptyView()
        }
    }

    private var number: Int? {
        if case .integer(let value)? = model.shownValue(of: option) { return value }
        return nil
    }

    private var string: String? {
        if case .string(let value)? = model.shownValue(of: option) { return value }
        return nil
    }

    /// The fixed values, plus the file's own when it is not one of them.
    private func choices(_ values: [String]) -> [String] {
        guard let string, !values.contains(string) else { return values }
        return values + [string]
    }

    private static func title(_ value: String) -> String {
        switch value {
        case "auto": return "Auto"
        case "inject": return "Inject"
        case "clipboard": return "Clipboard"
        case "OFF": return "Off"
        default: return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The list of word separators: one chip per entry and a field to add more.
private struct TokenRow: View {
    let model: AppModel
    let option: EngineOption
    @State private var newToken = ""

    private var isWritten: Bool { model.isWritten(option) }

    private var tokens: [String] {
        if case .list(let items)? = model.shownValue(of: option) { return items }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(isWritten ? Color.accentColor : .clear).frame(width: 6, height: 6)
                Text(option.title)
                Spacer()
                Tag(option.key, .yaml).help(option.key)
                if isWritten {
                    Button("Reset") { model.setEngineOption(option, to: nil) }.buttonStyle(.link)
                }
            }
            FlowLayout(spacing: 5) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    HStack(spacing: 3) {
                        Text(EngineOption.tokenName(token))
                            .font(.system(.callout, design: .monospaced))
                        Button {
                            var items = tokens
                            items.remove(at: index)
                            model.setEngineOption(option, to: .list(items))
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(EngineOption.tokenName(token))")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                }
                TextField(isWritten ? "add a token" : "Showing Espanso\u{2019}s defaults \u{00B7} add a token", text: $newToken)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 230)
                    .onSubmit(add)
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            Text("Type a character and press Return. The words space, tab, return and newline stand for those keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    private func add() {
        let typed = newToken.trimmingCharacters(in: .whitespaces)
        let token: String
        switch typed.lowercased() {
        case "": token = newToken.isEmpty ? "" : " "
        case "space": token = " "
        case "tab": token = "\t"
        case "return": token = "\r"
        case "newline": token = "\n"
        default: token = typed
        }
        newToken = ""
        guard !token.isEmpty, !tokens.contains(token) else { return }
        model.setEngineOption(option, to: .list(tokens + [token]))
    }
}

/// Lays chips out in rows, wrapping at the available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width.isFinite ? width : rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(Row(y: row.y + row.height + spacing))
                row = rows[rows.count - 1]
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x, size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: Statistics

struct StatisticsSettings: View {
    let model: AppModel

    var body: some View {
        SettingsPage {
            HStack(spacing: 6) {
                Text("Writes")
                Tag("config/default.yml", .yaml)
                Text("Espanso keeps the counts itself; Abbrio only reads them.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            SettingsCard {
                SettingsRow(
                    title: "Count how often each abbreviation is used",
                    note: model.supportsStatistics
                        ? "Espanso records the text you typed for each expansion and when, in stats.db in the config folder."
                        : "Needs Espanso 2.4.0 or later.",
                    isChanged: model.statisticsSetting != nil, showsDivider: false
                ) {
                    Tag("stats: enabled", .yaml).help("stats: enabled")
                    Toggle("Count how often each abbreviation is used", isOn: Binding(
                        get: { model.statisticsAreOn },
                        set: { model.setStatistics($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    if model.statisticsSetting != nil {
                        Button("Reset") { model.setStatistics(nil) }.buttonStyle(.link)
                    }
                }
            }
            .disabled(!model.canChangeEngineOptions || !model.supportsStatistics)

            Button("Open Statistics") { model.openWindow?("statistics") }
        }
    }
}
