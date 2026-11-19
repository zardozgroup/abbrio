public import SwiftUI
public import SnippetModel

/// The details pane on the right: the form for the selected item, and its YAML.
struct DetailView: View {
    @Bindable var model: AppModel
    @State private var tab = Tab.editor
    @State private var showsAdvanced = true
    @State private var yamlDraft: String?
    @State private var yamlError: String?
    @FocusState private var focus: FormField?

    private enum Tab: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case yaml = "YAML"
        var id: Self { self }
    }

    private enum FormField: Hashable {
        case abbreviation, description, expansion, yaml
    }

    var body: some View {
        VStack(spacing: 0) {
            if let set = model.selectedSet, set.isBroken, !model.isSearching {
                BrokenFileEditor(model: model, set: set)
                    .id(set.id)
            } else if let snippet = model.selectedSnippet {
                header(for: snippet)
                Group {
                    switch tab {
                    case .editor: editor(for: snippet)
                    case .yaml: yaml(for: snippet)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.right",
                    description: Text("Select an abbreviation to see its details.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: focus) { _, _ in
            // A field lost the keyboard: save what was typed.
            model.commitDraft()
        }
        .onChange(of: model.selectedSnippetID) { _, _ in
            yamlDraft = nil
            yamlError = nil
            if model.isAddingItem {
                tab = .editor
                focus = .abbreviation
            }
        }
    }

    // MARK: Header and footer

    private func header(for snippet: Snippet) -> some View {
        HStack {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.isAddingItem)

            Spacer()

            let rows = model.rows
            if let position = rows.firstIndex(where: { $0.id == snippet.id }) {
                Text("\(position + 1) of \(rows.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
            if let snippet = model.selectedSnippet {
                Text(snippet.id.file)
                    .font(.system(size: 11, design: .monospaced))
            } else if let file = model.selectedSet?.files.first {
                Text(file.path)
                    .font(.system(size: 11, design: .monospaced))
            } else {
                Text("No file")
            }
            Spacer(minLength: 8)
            if let status = SaveStatus(model.saveState) {
                Label(status.text, systemImage: status.systemImage)
                    .foregroundStyle(status.color)
                    .help(status.text)
            } else if let snippet = model.selectedSnippet, model.set(containing: snippet.id)?.isLocked == true {
                Text("Package, read-only")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: Editor tab

    private func binding<Value>(_ keyPath: WritableKeyPath<MatchDraft, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(
            get: { model.draft?[keyPath: keyPath] ?? fallback },
            set: { value in model.updateDraft { $0[keyPath: keyPath] = value } }
        )
    }

    private func editor(for snippet: Snippet) -> some View {
        let isLocked = model.formLockReason != nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.saveState == .conflict {
                    ConflictBanner(keepMine: model.keepMine, loadFromDisk: model.loadFromDisk)
                }
                if let reason = model.formLockReason {
                    Label(reason, systemImage: snippet.needsAdvancedYAML ? "curlybraces" : "lock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Group {
                    Field(snippet.isRegex ? "Pattern" : "Abbreviation") {
                        HStack(spacing: 4) {
                            let affixes = shownAffixes
                            if !affixes.prefix.isEmpty { affixText(affixes.prefix, "Prefix of this set") }
                            TextField("", text: abbreviationBinding(isRegex: snippet.isRegex), prompt: Text(snippet.isRegex ? "Pattern" : "Abbreviation"))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .autocorrectionDisabled()
                                .focused($focus, equals: .abbreviation)
                                .onSubmit { model.commitDraft() }
                            if !affixes.suffix.isEmpty { affixText(affixes.suffix, "Suffix of this set") }
                        }
                        abbreviationNotes
                        if snippet.isRegex { RegexPatternNotes(model: model) }
                    }

                    if !snippet.isRegex {
                        HStack(alignment: .top, spacing: 12) {
                            Field("Case") { casePicker }
                            Field("Expand") { expandPicker }
                        }
                    }

                    Field("Description") {
                        TextField("", text: binding(\.label, ""))
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .description)
                            .onSubmit { model.commitDraft() }
                    }

                }
                .disabled(isLocked)

                // Its controls lock themselves, so a locked item's text can still be scrolled and copied.
                ExpansionSection(model: model, snippet: snippet)

                if snippet.isRegex { RegexTester(model: model) }

                Divider()

                DisclosureGroup(isExpanded: $showsAdvanced) {
                    advanced
                        .padding(.top, 10)
                        .disabled(isLocked)
                } label: {
                    Text("Advanced")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    /// The set's prefix and suffix, when the item's triggers carry them.
    private var shownAffixes: (prefix: String, suffix: String) {
        guard model.triggerForm?.usesAffixes == true else { return ("", "") }
        return model.editingAffixes
    }

    private func affixText(_ text: String, _ help: String) -> some View {
        Text(text)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
            .help(help + ". Change it in Set Info.")
            .accessibilityLabel(help + ": " + text)
    }

    private func abbreviationBinding(isRegex: Bool) -> Binding<String> {
        if isRegex { return binding(\.abbreviation, "") }
        return Binding(
            get: { model.triggerForm?.abbreviation ?? "" },
            set: { value in model.updateTriggers { $0.abbreviation = value } }
        )
    }

    @ViewBuilder
    private var abbreviationNotes: some View {
        if let form = model.triggerForm, !form.usesAffixes {
            let affixes = model.editingAffixes
            Note(
                "This item doesn't carry the set's \(affixes.prefix.isEmpty ? "suffix" : "prefix"), so it is shown and saved as written.",
                systemImage: "info.circle", color: .secondary
            )
        }
        if let form = model.triggerForm, form.isCaseInsensitive, !form.abbreviation.isEmpty {
            Note(
                "Written as " + TriggerForm.variants(of: form.abbreviation).joined(separator: ", ")
                    + ". Other mixes of capitals won't expand.",
                systemImage: "textformat", color: .secondary
            )
        }
        if case .invalid(let message) = model.saveState {
            Note(message, systemImage: "exclamationmark.circle", color: .red)
        }
        let others = model.draftDuplicateSetNames
        if !others.isEmpty {
            Note(
                "Also used in \(others.joined(separator: ", ")). Espanso will ask which one to use.",
                systemImage: "exclamationmark.triangle", color: .orange
            )
        }
    }

    private var casePicker: some View {
        Picker("Case", selection: Binding(
            get: { model.caseMode },
            set: { model.setCaseMode($0) }
        )) {
            Text("Case must match").tag(CaseMode.mustMatch)
            Text("Case does not matter").tag(CaseMode.insensitive)
            Text("Case affects expansion").tag(CaseMode.affectsExpansion)
        }
        .labelsHidden()
    }

    private var expandPicker: some View {
        Picker("Expand", selection: Binding(
            get: {
                guard let options = model.draft?.options else { return ExpandChoice.onMatch }
                if options.word { return .wordBreak }
                if options.leftWord { return .wordStart }
                if options.rightWord { return .wordEnd }
                return .onMatch
            },
            set: { choice in
                model.updateDraft {
                    $0.options.word = choice == .wordBreak
                    $0.options.leftWord = choice == .wordStart
                    $0.options.rightWord = choice == .wordEnd
                }
                model.commitDraft()
            }
        )) {
            Text("At word break").tag(ExpandChoice.wordBreak)
            Text("On match").tag(ExpandChoice.onMatch)
            Divider()
            Text("At word start only").tag(ExpandChoice.wordStart)
            Text("At word end only").tag(ExpandChoice.wordEnd)
        }
        .labelsHidden()
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Field("Aliases") {
                    TokenField(
                        tokens: model.triggerForm?.aliases ?? [], prompt: "Add alias", monospaced: true
                    ) { aliases in
                        model.updateTriggers { $0.aliases = aliases }
                        model.commitDraft()
                    }
                }
                Field("Insert using") {
                    Picker("Insert using", selection: Binding(
                        get: { model.draft?.options.forceMode },
                        set: { mode in
                            model.updateDraft { $0.options.forceMode = mode }
                            model.commitDraft()
                        }
                    )) {
                        Text("Automatic").tag(ForceMode?.none)
                        Text("Keystrokes").tag(ForceMode?.some(.keys))
                        Text("Clipboard").tag(ForceMode?.some(.clipboard))
                    }
                    .labelsHidden()
                }
            }
            .disabled(model.draft?.isRegex == true)

            Field("Search terms") {
                TokenField(tokens: model.draft?.searchTerms ?? [], prompt: "Add search term") { terms in
                    model.updateDraft { $0.searchTerms = terms }
                    model.commitDraft()
                }
            }

            Toggle("Capitalize every word", isOn: Binding(
                get: { model.draft?.options.uppercaseStyle == .capitalizeWords },
                set: { isOn in
                    model.updateDraft { $0.options.uppercaseStyle = isOn ? .capitalizeWords : nil }
                    model.commitDraft()
                }
            ))
            .disabled(model.draft?.options.propagateCase != true)
            .help("Only with \"Case affects expansion\"")

            HStack {
                Toggle("Markdown without a new paragraph", isOn: Binding(
                    get: { model.draft?.options.paragraph == true },
                    set: { isOn in
                        model.updateDraft { $0.options.paragraph = isOn }
                        model.commitDraft()
                    }
                ))
                .disabled(!isMarkdown(model.draft?.expansion))
                Spacer()
                Text("Markdown only")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
    }

    private func isMarkdown(_ expansion: Expansion?) -> Bool {
        if case .markdown = expansion { return true }
        return false
    }

    // MARK: YAML tab

    private func yaml(for snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = yamlDraft {
                YAMLEditor(text: Binding(get: { text }, set: { yamlDraft = $0 }))
                    .focused($focus, equals: .yaml)
                if let yamlError {
                    Note(yamlError, systemImage: "exclamationmark.circle", color: .red)
                }
                HStack {
                    Text("The YAML is checked before it is saved.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        yamlDraft = nil
                        yamlError = nil
                    }
                    Button("Save") {
                        yamlError = model.saveYAML(text)
                        if yamlError == nil { yamlDraft = nil }
                    }
                    .keyboardShortcut("s")
                    .disabled(text == snippet.source)
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(snippet.source.isEmpty ? "The lines of this item could not be determined." : snippet.source)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Edit as YAML") {
                        model.commitDraft()
                        yamlDraft = model.selectedSnippet?.source ?? snippet.source
                        focus = .yaml
                    }
                    .disabled(!model.canEditYAML)
                    .help(model.canEditYAML ? "Change anything the form can't" : "This item can't be changed")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

private enum ExpandChoice: Hashable {
    case wordBreak, onMatch, wordStart, wordEnd
}

/// The words and colour for the save state under the details pane.
private struct SaveStatus {
    var text: String
    var systemImage: String
    var color: Color

    init?(_ state: SaveState) {
        switch state {
        case .idle:
            return nil
        case .invalid(let message):
            self.init(text: "Not saved · \(message)", systemImage: "exclamationmark.circle", color: .orange)
        case .failed(let message):
            self.init(text: "Not saved · \(message)", systemImage: "xmark.octagon", color: .red)
        case .conflict:
            self.init(text: "Changed by another program", systemImage: "exclamationmark.triangle", color: .orange)
        case .saved(let confirmation):
            switch confirmation {
            case .checking:
                self.init(text: "Saved", systemImage: "checkmark", color: .secondary)
            case .reloaded:
                self.init(text: "Saved · Espanso reloaded", systemImage: "checkmark.circle", color: .green)
            case .notRunning:
                self.init(text: "Saved · Espanso is not running", systemImage: "checkmark", color: .secondary)
            case .notConfirmed:
                self.init(text: "Saved · Espanso has not confirmed the reload", systemImage: "checkmark", color: .secondary)
            case .setIsOff:
                self.init(text: "Saved · this set is off", systemImage: "checkmark", color: .secondary)
            case .rejected(let message):
                self.init(text: "Saved, but Espanso reports: \(message)", systemImage: "xmark.octagon", color: .red)
            }
        }
    }

    private init(text: String, systemImage: String, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }
}

/// Shown when the item being edited was changed on disk by something else.
private struct ConflictBanner: View {
    let keepMine: () -> Void
    let loadFromDisk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This item was changed by another program while you were editing it.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep Mine", action: keepMine)
                Button("Load from Disk", action: loadFromDisk)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.5)))
    }
}

/// A small line of advice or warning under a field.
private struct Note: View {
    let text: String
    let systemImage: String
    let color: Color

    init(_ text: String, systemImage: String, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain monospaced text box for YAML.
private struct YAMLEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .accessibilityLabel("YAML")
    }
}

/// The whole text of a file that can't be parsed, so it can be put right.
private struct BrokenFileEditor: View {
    let model: AppModel
    let set: SnippetSet
    @State private var text = ""
    @State private var original = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This file can't be read. Fix the YAML to see its items.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
            if let problem = set.problems.first(where: { $0.severity == .unreadable }) {
                Text((problem.line.map { "Line \($0): " } ?? "") + problem.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            YAMLEditor(text: $text)
            if let error {
                Note(error, systemImage: "exclamationmark.circle", color: .red)
            }
            HStack {
                Spacer()
                Button("Revert") {
                    text = original
                    error = nil
                }
                .disabled(text == original)
                Button("Save") {
                    error = model.saveFileText(text, of: set)
                }
                .keyboardShortcut("s")
                .disabled(text == original)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            original = model.fileText(of: set) ?? ""
            text = original
        }
    }
}

/// A list of short texts with a field to add one more. Each can be removed with its own button.
private struct TokenField: View {
    let tokens: [String]
    let prompt: String
    var monospaced = false
    let onChange: ([String]) -> Void
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !tokens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(tokens.enumerated()), id: \.offset) { position, token in
                            HStack(spacing: 3) {
                                Text(token)
                                    .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                                Button {
                                    var remaining = tokens
                                    remaining.remove(at: position)
                                    onChange(remaining)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(token)")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            TextField("", text: $entry, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .autocorrectionDisabled()
                .onSubmit(add)
        }
    }

    private func add() {
        let value = monospaced ? entry : entry.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !tokens.contains(value) else { return }
        onChange(tokens + [value])
        entry = ""
    }
}

// MARK: - Building blocks

private struct FieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct Field<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
