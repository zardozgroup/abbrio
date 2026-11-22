import AppKit
public import SwiftUI
import ConfigStore
import SnippetModel
import UniformTypeIdentifiers

/// What is known about an application on this Mac.
private struct AppIdentity {
    var name: String
    var icon: NSImage?
    var bundlePath: String?

    /// Looks an application up by its bundle identifier.
    static func find(bundleID: String) -> AppIdentity {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AppIdentity(name: bundleID, icon: nil, bundlePath: nil)
        }
        return AppIdentity(
            name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
            icon: NSWorkspace.shared.icon(forFile: url.path),
            bundlePath: url.path
        )
    }
}

/// The Apps window: applications on the left, and on the right which sets are on in the selected one.
public struct AppsWindow: View {
    @Bindable private var model: AppModel
    /// The selected config file's path, or `allOthers` for the first row.
    @State private var selection: String? = AppsWindow.allOthers
    @State private var identities: [String: AppIdentity] = [:]
    @State private var showsAdvanced = false
    @State private var showsDetectHelp = false
    @State private var isSearching = false
    @State private var appAwaitingRemoval: String?

    private static let allOthers = "\u{0}all-others"

    /// - Parameter path: The config file of the application to show first. Nil shows all other applications.
    public init(model: AppModel, selecting path: String? = nil) {
        self.model = model
        _selection = State(initialValue: path ?? AppsWindow.allOthers)
    }

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .task { if !model.hasLoaded { await model.load() } }
        .alert("Abbrio", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .confirmationDialog(
            "Remove \(title(forApp: appAwaitingRemoval)) from the list?",
            isPresented: Binding(get: { appAwaitingRemoval != nil }, set: { if !$0 { appAwaitingRemoval = nil } })
        ) {
            Button("Move Config File to Trash", role: .destructive) {
                if let path = appAwaitingRemoval {
                    model.removeApp(path)
                    selection = Self.allOthers
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(appAwaitingRemoval ?? "") goes to the Trash, where you can get it back. The application then behaves like all other applications.")
        }
    }

    // MARK: Application list

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Applications") {
                    AppRow(
                        icon: nil, symbol: "square.grid.2x2.fill",
                        title: model.appConfigs.isEmpty ? "All Applications" : "All Other Applications",
                        subtitle: "config/default.yml + file names", tag: nil
                    )
                    .tag(Self.allOthers)
                    ForEach(model.appConfigs) { file in
                        let identity = identity(for: file)
                        AppRow(
                            icon: identity?.icon, symbol: "app.dashed",
                            title: identity?.name ?? (file.path as NSString).lastPathComponent,
                            subtitle: subtitle(for: file),
                            tag: model.isAllOff(inApp: file.path) ? "enable: false" : nil
                        )
                        .tag(file.path)
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Button("Open in External Editor") { NSWorkspace.shared.open(file.url) }
                            Divider()
                            Button("Remove…") { appAwaitingRemoval = file.path }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .dropDestination(for: URL.self) { urls, _ in
                var added = false
                for url in urls where url.pathExtension == "app" {
                    added = add(appAt: url) || added
                }
                return added
            }

            Text("Add an app by dragging it here from the Finder, or use + to pick a running app or search Spotlight.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            Divider()
            HStack(spacing: 12) {
                Menu {
                    let running = runningApps
                    if !running.isEmpty {
                        Section("Running") {
                            ForEach(running, id: \.bundleID) { app in
                                Button(app.name) { add(bundleID: app.bundleID, bundlePath: app.path) }
                            }
                        }
                    }
                    Button("Search…") { isSearching = true }
                    Button("Choose Application…", action: chooseApp)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add an application")
                .disabled(model.configFolder == nil)
                .popover(isPresented: $isSearching, arrowEdge: .top) {
                    AppSearchView { url in
                        isSearching = false
                        add(appAt: url)
                    }
                }

                Button {
                    appAwaitingRemoval = selection
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Remove the selected application")
                .disabled(selectedFile == nil)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var selectedFile: ConfigFile? {
        guard let selection, selection != Self.allOthers else { return nil }
        return model.appConfig(selection)
    }

    private func identity(for file: ConfigFile) -> AppIdentity? {
        guard let bundleID = model.bundleID(of: file) else { return nil }
        if let known = identities[bundleID] { return known }
        let found = AppIdentity.find(bundleID: bundleID)
        Task { identities[bundleID] = found }
        return found
    }

    private func title(forApp path: String?) -> String {
        guard let file = model.appConfig(path) else { return "the application" }
        return identity(for: file)?.name ?? (file.path as NSString).lastPathComponent
    }

    private func subtitle(for file: ConfigFile) -> String {
        if model.isAllOff(inApp: file.path) { return "Expansion turned off" }
        let count = model.changeCount(inApp: file.path)
        switch count {
        case 0: return "Same as default"
        case 1: return "1 change from default"
        default: return "\(count) changes from default"
        }
    }

    // MARK: Adding applications

    private var runningApps: [(name: String, bundleID: String, path: String?)] {
        let listed = Set(model.appConfigs.compactMap { model.bundleID(of: $0) })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String, path: String?)? in
                guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier,
                      !listed.contains(bundleID)
                else { return nil }
                return (app.localizedName ?? bundleID, bundleID, app.bundleURL?.path)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            add(appAt: url)
        }
    }

    @discardableResult
    private func add(appAt url: URL) -> Bool {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            model.alertMessage = "\(url.lastPathComponent) has no bundle identifier, so Espanso can't tell it apart."
            return false
        }
        return add(bundleID: bundleID, bundlePath: url.path)
    }

    @discardableResult
    private func add(bundleID: String, bundlePath: String?) -> Bool {
        guard let path = model.addApp(bundleID: bundleID, bundlePath: bundlePath) else { return false }
        selection = path
        return true
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let file = selectedFile {
            appDetail(file)
        } else {
            allOthersDetail
        }
    }

    private var allOthersDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    iconView(nil, symbol: "square.grid.2x2.fill", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.appConfigs.isEmpty ? "All Applications" : "All Other Applications")
                            .font(.system(size: 17, weight: .bold))
                        Text("config/default.yml + file names")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                grid { set in
                    SetSwitchRow(
                        name: set.name, isOn: model.isOnEverywhere(set), isDifferent: false,
                        note: set.kind == .package
                            ? "Installed packages are on everywhere. Turn one off per application."
                            : (set.isEnabled ? "On" : "Off · file is \((set.id as NSString).lastPathComponent)"),
                        tag: nil, isDisabled: set.kind == .package
                    ) { isOn in
                        model.setEnabled(isOn, for: set.id)
                    }
                }
                Text("Unchecking a set here puts an underscore in front of its file name, which is how Espanso leaves a file out. Add an application on the left to make exceptions for it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    private func appDetail(_ file: ConfigFile) -> some View {
        let identity = identity(for: file)
        let name = identity?.name ?? (file.path as NSString).lastPathComponent
        let isAllOff = model.isAllOff(inApp: file.path)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    iconView(identity?.icon, symbol: "app.dashed", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 17, weight: .bold))
                        Text((model.bundleID(of: file) ?? filterSummary(file)) + " · writes " + file.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("Turn all off", isOn: Binding(
                        get: { isAllOff },
                        set: { model.setAllOff($0, inApp: file.path) }
                    ))
                    .toggleStyle(.switch)
                    .help("Writes enable: false, so nothing expands in \(name). The choices below are kept.")
                }

                grid { set in
                    let state = model.state(of: set, inApp: file.path)
                    SetSwitchRow(
                        name: set.name, isOn: state.isOn, isDifferent: state != .same(isOn: state.isOn),
                        note: note(for: state, set: set), tag: tag(for: state), isDisabled: isAllOff
                    ) { isOn in
                        model.setOn(isOn, set, inApp: file.path)
                    }
                }

                advanced(file, name: name)
                generatedFile(file, name: name, bundlePath: identity?.bundlePath)

                Divider()
                HStack {
                    Button("Show what Espanso sees") { showsDetectHelp = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showsDetectHelp, arrowEdge: .top) {
                            Text("Click into a text field in \(name) and type #detect#. Espanso shows a notification with the window title, the executable and the class it detected. The class is what this file's filter is compared with.")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(width: 320)
                        }
                    Spacer()
                    Text("Type #detect# in \(name) to see its title, exec and class.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func filterSummary(_ file: ConfigFile) -> String {
        if let filter = file.filterClass { return "class " + filter }
        if let filter = file.filterExec { return "exec " + filter }
        if let filter = file.filterTitle { return "title " + filter }
        return ""
    }

    private func note(for state: AppSetState, set: SnippetSet) -> String {
        switch state {
        case .same:
            return set.kind == .package
                ? "Same as All Other Applications · unchecking excludes its folder"
                : "Same as All Other Applications"
        case .onHere:
            return "On here, off elsewhere (file is \((set.id as NSString).lastPathComponent))"
        case .offHere:
            return "Off here, on elsewhere"
        }
    }

    private func tag(for state: AppSetState) -> String? {
        switch state {
        case .same: return nil
        case .onHere: return "extra_includes"
        case .offHere: return "extra_excludes"
        }
    }

    /// The box with a checkbox per set, grouped the way the main window's sidebar is.
    private func grid(@ViewBuilder row: @escaping (SnippetSet) -> some View) -> some View {
        VStack(spacing: 0) {
            let groups: [(String, SnippetSet.Kind)] = [
                ("Abbreviation Sets", .abbreviations), ("Regular Expressions", .regularExpressions), ("Packages", .package),
            ]
            ForEach(groups, id: \.0) { title, kind in
                let sets = model.sets(ofKind: kind)
                if !sets.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    ForEach(sets) { set in
                        Divider()
                        row(set)
                    }
                    if kind != .package { Divider() }
                }
            }
            if model.sets.isEmpty {
                Text("There are no sets yet.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    // MARK: Advanced options

    private func advanced(_ file: ConfigFile, name: String) -> some View {
        let own = AppModel.appOptionKeys.filter { file.values[$0] != nil }
        return DisclosureGroup(isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AppModel.appOptionKeys, id: \.self) { key in
                    AppOptionRow(
                        key: key, value: file.values[key], inherited: model.inheritedOption(key)
                    ) { value in
                        model.setOption(key, value, inApp: file.path)
                    }
                    .id(file.path + key + (file.values[key] ?? ""))
                }
                Text("An empty field uses the value from default.yml, shown in grey.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Advanced for \(name)")
                    .font(.system(size: 12, weight: .semibold))
                Text(AppModel.appOptionKeys.joined(separator: ", ")
                    + (own.isEmpty ? " · all inherited from default.yml" : " · \(own.count) set here"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Generated file

    private func generatedFile(_ file: ConfigFile, name: String, bundlePath: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Generated file")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                overlapNote(file, name: name, bundlePath: bundlePath)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted(model.configText(file.path)))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            if let problem = file.problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func overlapNote(_ file: ConfigFile, name: String, bundlePath: String?) -> some View {
        if let overlaps = model.overlaps(forApp: file.path, bundlePath: bundlePath) {
            if overlaps.isEmpty {
                Label("No other config in config/ matches \(name)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(overlaps) { overlap in
                        Label(text(for: overlap, name: name), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(overlap.wins ? .red : .orange)
                    }
                }
                .help("Espanso uses one application config at a time: the first that matches, in file-name order.")
            }
        } else {
            Label("This filter was written by hand, so overlaps can't be checked", systemImage: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func text(for overlap: AppOverlap, name: String) -> String {
        if !overlap.isCertain { return "\(overlap.path) may also match \(name)" }
        return overlap.wins
            ? "\(overlap.path) also matches \(name) and sorts first, so Espanso uses it instead"
            : "\(overlap.path) also matches \(name); this file sorts first and is used"
    }

    /// Colours keys, strings and comments of a short YAML file.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.drop { $0 == " " }
            var piece: AttributedString
            if content.first == "#" {
                piece = AttributedString(String(line))
                piece.foregroundColor = .secondary
            } else if let colon = line.firstIndex(of: ":"), content.first != "-" {
                var key = AttributedString(String(line[..<colon]))
                key.foregroundColor = Color(nsColor: .systemBlue)
                var rest = AttributedString(String(line[colon...].prefix(1)))
                var value = AttributedString(String(line[colon...].dropFirst()))
                value.foregroundColor = Color(nsColor: .systemRed)
                rest.foregroundColor = .primary
                piece = key + rest + value
            } else if let dash = line.firstIndex(of: "-") {
                piece = AttributedString(String(line[...dash]))
                var value = AttributedString(String(line[line.index(after: dash)...]))
                value.foregroundColor = Color(nsColor: .systemRed)
                piece += value
            } else {
                piece = AttributedString(String(line))
            }
            result += piece + AttributedString("\n")
        }
        return result
    }

    private func iconView(_ icon: NSImage?, symbol: String, size: CGFloat) -> some View {
        AppIcon(icon: icon, symbol: symbol, size: size)
    }
}

// MARK: - Pieces

private struct AppIcon: View {
    let icon: NSImage?
    let symbol: String
    let size: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.secondary, in: RoundedRectangle(cornerRadius: size * 0.22))
                .accessibilityHidden(true)
        }
    }
}

private struct AppRow: View {
    let icon: NSImage?
    let symbol: String
    let title: String
    let subtitle: String
    let tag: String?

    var body: some View {
        HStack(spacing: 9) {
            AppIcon(icon: icon, symbol: symbol, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let tag {
                Tag(tag, .yaml)
            }
        }
        .padding(.vertical, 3)
    }
}

/// One line of the grid: a checkbox, the set's name and how it compares with all other applications.
private struct SetSwitchRow: View {
    let name: String
    let isOn: Bool
    let isDifferent: Bool
    let note: String
    let tag: String?
    let isDisabled: Bool
    let change: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { isOn }, set: change)) {
                Text(name)
                    .font(.system(size: 13, weight: isDifferent ? .semibold : .regular))
                    .frame(width: 170, alignment: .leading)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(isDisabled)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(isDifferent ? AnyShapeStyle(Color(nsColor: .linkColor)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let tag {
                Tag(tag, .yaml)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isDifferent ? Color.accentColor.opacity(0.06) : .clear)
    }
}

/// One per-application option: its own value, or the inherited one in grey.
private struct AppOptionRow: View {
    let key: String
    let value: String?
    let inherited: String?
    let change: (ConfigValue?) -> Void
    @State private var text = ""
    @State private var problem: String?

    private var isNumber: Bool {
        key != "backend" && key != "paste_shortcut"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            if key == "backend" {
                Picker(key, selection: Binding(get: { value ?? "" }, set: { change($0.isEmpty ? nil : .string($0)) })) {
                    Text("Inherited" + (inherited.map { " (\($0))" } ?? "")).tag("")
                    ForEach(["Auto", "Clipboard", "Inject"], id: \.self) { Text($0).tag($0) }
                    if let value, !["Auto", "Clipboard", "Inject"].contains(value) { Text(value).tag(value) }
                }
                .labelsHidden()
                .frame(width: 200)
            } else {
                TextField("", text: $text, prompt: Text(inherited ?? "Espanso's default"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 200)
                    .autocorrectionDisabled()
                    .onSubmit(commit)
                    .accessibilityLabel(key)
            }
            if value != nil {
                Tag("set here", .yaml)
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .onAppear { text = value ?? "" }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        problem = nil
        if trimmed.isEmpty {
            change(nil)
        } else if isNumber {
            guard let number = Int(trimmed), number >= 0 else {
                problem = "Enter a whole number."
                return
            }
            change(.integer(number))
        } else {
            change(.string(trimmed))
        }
    }
}

/// Finds applications with Spotlight.
private struct AppSearchView: View {
    let choose: (URL) -> Void
    @State private var text = ""
    @State private var search = AppSearch()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search applications", text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, value in search.find(value) }
            if search.results.isEmpty {
                Text(text.isEmpty ? "Type part of an application's name." : "No applications found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(search.results, id: \.self) { url in
                            Button {
                                choose(url)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onDisappear { search.stop() }
    }
}

@Observable
private final class AppSearch {
    private(set) var results: [URL] = []
    private let query = NSMetadataQuery()
    private var observer: (any NSObjectProtocol)?

    func find(_ text: String) {
        query.stop()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            }
        }
        query.predicate = NSPredicate(
            format: "kMDItemContentType == 'com.apple.application-bundle' AND kMDItemDisplayName CONTAINS[cd] %@", trimmed
        )
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.start()
    }

    func stop() {
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func collect() {
        query.disableUpdates()
        var found: [URL] = []
        for case let item as NSMetadataItem in query.results.prefix(40) {
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                found.append(URL(fileURLWithPath: path))
            }
        }
        results = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        query.enableUpdates()
    }
}


#if DEBUG
#Preview("Apps") {
    @Previewable @State var model = WindowPreview.makeModel()
    AppsWindow(model: model)
        .frame(width: 1080, height: 760)
}
#endif

#if DEBUG
import EspansoCLI
import Foundation

/// Isolated dependencies for window previews, separate from the user's configuration and services.
enum WindowPreview {
    static func makeModel(quickDefine: Bool = false) -> AppModel {
        let identifier = "AbbrioPreview-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: identifier) else {
            preconditionFailure("Could not create preview preferences.")
        }
        let model = AppModel(
            environment: AppEnvironment(
                configFolderOverride: FileManager.default.temporaryDirectory
                    .appendingPathComponent(identifier, isDirectory: true),
                fallbackConfigFolders: []
            ),
            runner: PreviewCommandRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in false }),
            defaults: defaults,
            isSecureInputOn: { false },
            readClipboard: { nil },
            hub: HubService(fetch: { _ in throw URLError(.notConnectedToInternet) }, cacheFolder: nil)
        )
        // Start with an empty offline catalog without showing a download failure on appearance.
        model.packageCenter.catalogDate = Date()
        if quickDefine {
            model.quickDefine = QuickDefineRequest(
                source: .clipboard,
                text: "Thank you for getting in touch. I will reply shortly."
            )
        }
        return model
    }
}

private struct PreviewCommandRunner: CommandRunner {
    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        throw CommandError.launchFailed("Commands are unavailable in window previews.")
    }
}

/// Keeps Quick Search interactions inside the preview.
final class PreviewInsertionDevice: InsertionDevice {
    var isTrusted: Bool { false }
    var modifiersAreDown: Bool { false }
    var clipboardChangeCount: Int { 0 }

    func askForTrust() {}
    func saveClipboard() -> ClipboardContents { ClipboardContents() }
    func restoreClipboard(_ contents: ClipboardContents) {}
    func setClipboard(_ text: String) {}
    func paste() {}
    func moveLeft(_ count: Int) {}
    func selectedText() -> String? { nil }
    func copy() {}
    func clipboardText() -> String? { nil }
}
#endif
