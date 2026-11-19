import AppKit
public import SwiftUI
public import SnippetModel

/// The list of sets and packages, with the buttons that add, remove and switch them.
struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var renamingID: String?
    @State private var newName = ""
    @State private var renameAwaitingConfirmation: (id: String, name: String)?
    @FocusState private var renameFieldIsFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: $model.selectedSetID) {
            section("Abbreviation Sets", kind: .abbreviations)
            section("Regular Expressions", kind: .regularExpressions)
            section("Packages", kind: .package)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .confirmationDialog(
            deletionTitle, isPresented: Binding(
                get: { model.setAwaitingDeletion != nil },
                set: { if !$0 { model.setAwaitingDeletion = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let id = model.setAwaitingDeletion { model.deleteSet(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file goes to the Trash, where you can get it back. Lines in config files that mention it are removed.")
        }
        .confirmationDialog(
            "Also rename the file?", isPresented: Binding(
                get: { renameAwaitingConfirmation != nil },
                set: { if !$0 { renameAwaitingConfirmation = nil } }
            ), presenting: renameAwaitingConfirmation
        ) { request in
            Button("Keep File Name") { model.renameSet(request.id, to: request.name, renamingFile: false) }
            Button("Rename File") { model.renameSet(request.id, to: request.name, renamingFile: true) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("The set will be called \u{201C}\(request.name)\u{201D}. Its file \((request.id as NSString).lastPathComponent) can stay as it is, or become \(model.fileName(forSetNamed: request.name, renaming: request.id)).")
        }
    }

    private var deletionTitle: String {
        guard let set = model.sets.first(where: { $0.id == model.setAwaitingDeletion }) else { return "Delete the set?" }
        let count = set.snippets.count
        let items = count == 1 ? "1 item" : "\(count) items"
        return "Move \u{201C}\(set.name)\u{201D} and its \(items) to the Trash?"
    }

    @ViewBuilder
    private func section(_ title: String, kind: SnippetSet.Kind) -> some View {
        let sets = model.sets(ofKind: kind)
        if !sets.isEmpty {
            Section(title) {
                ForEach(sets) { set in
                    row(for: set)
                        .tag(set.id)
                }
                .onMove { source, destination in
                    model.moveSets(ofKind: kind, fromOffsets: source, toOffset: destination)
                }
            }
        }
    }

    private func row(for set: SnippetSet) -> some View {
        SetRow(
            set: set,
            hasDuplicates: model.duplicates.hasConflicts(in: set),
            isRenaming: renamingID == set.id,
            newName: $newName,
            renameFieldIsFocused: $renameFieldIsFocused,
            toggle: { model.setEnabled(!set.isEnabled, for: set.id) },
            select: { model.selectedSetID = set.id },
            beginRename: { beginRename(set) },
            endRename: { commit in endRename(set, commit: commit) }
        )
        .dropDestination(for: String.self) { payloads, _ in
            let ids = payloads.compactMap(ItemDrag.id(from:))
            guard !ids.isEmpty, !set.isLocked, !set.isBroken else { return false }
            // Holding Option copies, as in the Finder.
            return model.moveItems(ids, toSet: set.id, copying: NSEvent.modifierFlags.contains(.option))
        }
        .contextMenu {
            if !set.isLocked {
                Button(set.kind == .regularExpressions ? "New Rule" : "New Abbreviation") { model.newItem(in: set.id) }
                    .disabled(set.isBroken)
                Button("Set Info…") { model.showSetInfo(for: set.id) }
                Button("Rename…") { beginRename(set) }
                Button("Duplicate") { model.duplicateSet(set.id) }
                Button(set.isEnabled ? "Turn Off" : "Turn On") { model.setEnabled(!set.isEnabled, for: set.id) }
                Divider()
            }
            if let url = set.files.first?.url {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open in External Editor") { NSWorkspace.shared.open(url) }
            }
            Button("Export as CSV\u{2026}") { TransferPanels.exportList(of: set.id, from: model) }
                .disabled(!model.canExport(set.id))
            if !set.isLocked {
                Button("Export as Espanso Package\u{2026}") { model.setBeingExported = set.id }
                    .disabled(!model.canExportAsPackage(set.id))
                Divider()
                Button("Delete…") { model.setAwaitingDeletion = set.id }
            }
        }
    }

    private func beginRename(_ set: SnippetSet) {
        guard !set.isLocked else { return }
        newName = set.name
        renamingID = set.id
        renameFieldIsFocused = true
    }

    private func endRename(_ set: SnippetSet, commit: Bool) {
        guard renamingID == set.id else { return }
        renamingID = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard commit, !name.isEmpty, name != set.name else { return }
        if model.renameWouldChangeFile(set.id, to: name) {
            switch model.preferences.renameFilePolicy {
            case .ask: renameAwaitingConfirmation = (set.id, name)
            case .always: model.renameSet(set.id, to: name, renamingFile: true)
            case .never: model.renameSet(set.id, to: name, renamingFile: false)
            }
        } else {
            model.renameSet(set.id, to: name, renamingFile: false)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Menu {
                    Button("New Abbreviation Set…") { model.isAskingForNewSetName = true }
                    Button("New Regular Expression Set…") { model.isAskingForNewRegexSetName = true }
                    Divider()
                    Button("Install Package\u{2026}") { model.showPackages(.hub) }
                    Button("Install from Git URL\u{2026}") { model.showPackages(.installed, askingForGitURL: true) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New set")
                .disabled(model.configFolder == nil)

                Button {
                    model.setAwaitingDeletion = model.selectedSetID
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Delete the selected set")
                .disabled(!model.canChangeSelectedSet)

                Button {
                    model.showSetInfo()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Set Info")
                .disabled(!model.canChangeSelectedSet)
                Spacer()
                Button {
                    openWindow(id: "apps")
                } label: {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderless)
                .help("Choose which sets are on in each application")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private struct SetRow: View {
    let set: SnippetSet
    let hasDuplicates: Bool
    let isRenaming: Bool
    @Binding var newName: String
    var renameFieldIsFocused: FocusState<Bool>.Binding
    let toggle: () -> Void
    let select: () -> Void
    let beginRename: () -> Void
    let endRename: (_ commit: Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: set.isEnabled ? "checkmark.square.fill" : "square")
                    .foregroundStyle(set.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(set.isLocked)
            .help(set.isEnabled
                ? "On in all applications. Click to turn off."
                : "Off: Espanso does not load files whose names start with an underscore. Click to turn on.")
            .accessibilityLabel(set.isEnabled ? "On" : "Off")

            if isRenaming {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .focused(renameFieldIsFocused)
                    .onSubmit { endRename(true) }
                    .onExitCommand { endRename(false) }
                    .onChange(of: renameFieldIsFocused.wrappedValue) { _, isFocused in
                        if !isFocused { endRename(true) }
                    }
            } else {
                Text(set.name)
                    .lineLimit(1)
                    .foregroundStyle(set.isEnabled ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // A double-click gesture alone would hold back single clicks on the name, so the list
                    // would not always select the row. Both are recognised side by side, and the single
                    // click selects the row itself.
                    .simultaneousGesture(TapGesture(count: 2).onEnded(beginRename))
                    .simultaneousGesture(TapGesture().onEnded(select))
            }

            Spacer(minLength: 4)

            if set.isBroken {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(brokenHelp)
                    .accessibilityLabel("File can't be read")
            } else if hasDuplicates || !set.problems.isEmpty {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .help(hasDuplicates ? "Some triggers are also used elsewhere" : "Part of the file was skipped")
                    .accessibilityLabel("Has warnings")
            }

            if set.isLocked {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .help("Packages can't be edited")
                    .accessibilityLabel("Locked")
            } else {
                Text("\(set.snippets.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .help(set.files.first?.path ?? set.id)
    }

    private var brokenHelp: String {
        guard let problem = set.problems.first(where: { $0.severity == .unreadable }) else { return "" }
        if let line = problem.line {
            return "Line \(line): \(problem.message)"
        }
        return problem.message
    }
}

/// What is dragged when an item is pulled from the list onto a set.
nonisolated enum ItemDrag {
    private static let marker = "abbrio-item"

    static func payload(for id: Snippet.ID) -> String {
        [marker, id.file, String(id.index)].joined(separator: "\n")
    }

    static func id(from payload: String) -> Snippet.ID? {
        let parts = payload.components(separatedBy: "\n")
        guard parts.count == 3, parts[0] == marker, let index = Int(parts[2]) else { return nil }
        return Snippet.ID(file: parts[1], index: index)
    }
}
