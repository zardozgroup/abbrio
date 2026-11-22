import AppKit
public import SwiftUI
public import SnippetModel

/// The main window: sets on the left, the abbreviation list in the middle and the details on the right.
public struct MainWindow: View {
    @Bindable private var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var newSetName = ""
    @State private var isShowingHelp = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            HSplitView {
                SnippetListView(model: model)
                    .frame(minWidth: 460, idealWidth: 640)
                    .layoutPriority(1)
                DetailView(model: model)
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 420)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard model.hasLoaded else { return }
            Task { await model.load() }
        }
        .frame(minWidth: 1040, minHeight: 560)
        .background(ToolbarLabels())
        .onAppear {
            model.undoManager = undoManager
            model.openWindow = { [openWindow] id in openWindow(id: id) }
            model.openSettings = { [openSettings] in openSettings() }
            // With "Show main window at launch" off, the window the system opens at launch is closed again.
            // It waits for the next turn of the run loop: closing the window while window restoration is still
            // ordering it in can leave it on screen with every click and key press ignored.
            if model.takeLaunchWindowDismissal() {
                Task { @MainActor in dismissWindow(id: "main") }
            }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .alert("New Abbreviation Set", isPresented: $model.isAskingForNewSetName) {
            TextField("Name", text: $newSetName)
            Button("Create") {
                model.createSet(named: newSetName)
                newSetName = ""
            }
            .disabled(newSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newSetName = "" }
        } message: {
            Text("The set is saved as a new file in the match folder.")
        }
        .alert("New Regular Expression Set", isPresented: $model.isAskingForNewRegexSetName) {
            TextField("Name", text: $newSetName)
            Button("Create") {
                model.createSet(named: newSetName, forRegularExpressions: true)
                newSetName = ""
            }
            .disabled(newSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newSetName = "" }
        } message: {
            Text("Its rules expand text that matches a pattern. The set is saved as a new file in the match folder.")
        }
        .sheet(isPresented: Binding(
            get: { model.setShowingInfo != nil },
            set: { if !$0 { model.setShowingInfo = nil } }
        )) {
            if let id = model.setShowingInfo {
                SetInfoSheet(model: model, setID: id)
            }
        }
        .sheet(item: $model.pendingImport) { pending in
            ImportSheet(model: model, pending: pending)
        }
        .sheet(isPresented: Binding(
            get: { model.setBeingExported != nil },
            set: { if !$0 { model.setBeingExported = nil } }
        )) {
            if let id = model.setBeingExported {
                PackageExportSheet(model: model, setID: id)
            }
        }
        .alert("Abbrio", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var title: String {
        if model.isSearching { return "Search Results" }
        return model.selectedSet?.name ?? "Abbrio"
    }

    private var subtitle: String {
        if model.isSearching {
            let count = model.rows.count
            return count == 1 ? "1 match in all sets" : "\(count) matches in all sets"
        }
        guard let set = model.selectedSet else { return "" }
        if set.isBroken { return "Can't be read" }
        let count = set.snippets.count
        switch set.kind {
        case .regularExpressions:
            return count == 1 ? "1 rule" : "\(count) rules"
        default:
            return count == 1 ? "1 abbreviation" : "\(count) abbreviations"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarButton(title: "Packages", systemImage: "shippingbox") { openWindow(id: "packages") }
            ToolbarButton(title: "Statistics", systemImage: "chart.bar") { openWindow(id: "statistics") }
            ToolbarButton(title: "Apps", systemImage: "square.grid.2x2") { openWindow(id: "apps") }
            ToolbarButton(title: "Settings", systemImage: "gearshape") { openSettings() }

            Menu {
                Button("Import CSV or TSV\u{2026}") { TransferPanels.chooseImport(for: model) }
                    .disabled(model.configFolder == nil)
                Button("Export Set as CSV\u{2026}") {
                    if let id = model.selectedSetID { TransferPanels.exportList(of: id, from: model) }
                }
                .disabled(!model.canExport(model.selectedSetID))
                Button("Export Set as Espanso Package\u{2026}") { model.setBeingExported = model.selectedSetID }
                    .disabled(!model.canExportAsPackage(model.selectedSetID))
                Button("Install from Git URL\u{2026}") { model.showPackages(.installed, askingForGitURL: true) }
                    .disabled(model.configFolder == nil)
                Divider()
                Button("Reveal Config Folder") {
                    if let folder = model.configFolder {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                .disabled(model.configFolder == nil)
                Button("Open in External Editor") {
                    if let url = model.selectedSet?.files.first?.url {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(model.selectedSet?.files.isEmpty ?? true)
                Divider()
                Button("Restart Espanso") { Task { await model.restartEngine() } }
                    .disabled(model.engineStatus == .notInstalled)
            } label: {
                ToolbarButtonLabel(title: "Action", systemImage: "ellipsis.circle")
            }

            ToolbarButton(title: "Help", systemImage: "questionmark.circle") { isShowingHelp.toggle() }
                .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) { HelpPanel() }
        }

        // The pill draws its own tinted capsule. On macOS 26 and later the toolbar would wrap it in a
        // second, glass capsule of its own size, so that one is switched off.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                StatusPill(status: model.engineStatus, version: model.engineVersion)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                StatusPill(status: model.engineStatus, version: model.engineVersion)
            }
        }
    }
}

private struct ToolbarButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
    }
}

private struct ToolbarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarButtonLabel(title: title, systemImage: systemImage)
        }
        .help(title)
    }
}

/// Shows each toolbar button's name under its icon, as the main window's design does.
private struct ToolbarLabels: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window until after this call returns.
        Task { [weak view] in
            view?.window?.toolbar?.displayMode = .iconAndLabel
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.toolbar?.displayMode = .iconAndLabel
    }
}

/// The coloured pill that says whether Espanso is running.
struct StatusPill: View {
    let status: EngineStatus
    let version: EngineVersion?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Espanso status: \(title)")
    }

    private var title: String {
        switch status {
        case .running: return "Running"
        case .paused: return "Paused"
        case .secureInput: return "Secure Input"
        case .notRunning: return "Not running"
        case .notInstalled: return "Espanso not found"
        }
    }

    private var color: Color {
        switch status {
        case .running: return .green
        case .paused, .secureInput: return .orange
        case .notRunning: return .secondary
        case .notInstalled: return .red
        }
    }

    private var help: String {
        switch status {
        case .notInstalled:
            return "The espanso program was not found. Abbreviations can be viewed but will not expand."
        default:
            if let version { return "Espanso \(version)" }
            return title
        }
    }
}

#if DEBUG
#Preview("Main Window") {
    @Previewable @State var model = WindowPreview.makeModel()
    MainWindow(model: model)
        .frame(width: 1280, height: 800)
}
#endif
