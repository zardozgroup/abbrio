import SwiftUI
import SnippetModel

/// The Set Info sheet: a set's name, prefix and suffix, defaults for new items, and notes.
struct SetInfoSheet: View {
    let model: AppModel
    let setID: String
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var info = SetInfo()
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var selectedVariable: String?
    @State private var variableRequest: VariableRequest?
    @State private var variableError: String?
    /// Answers to the two questions OK may have to ask. Nil until asked.
    @State private var adoptsAffixes: Bool?
    @State private var renamesFile: Bool?
    @State private var isAskingAboutAffixes = false
    @State private var isAskingAboutFile = false

    private var set: SnippetSet? {
        model.sets.first { $0.id == setID }
    }

    private var preview: AppModel.AffixPreview {
        model.affixPreview(for: setID, prefix: info.prefix, suffix: info.suffix)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            nameField
            affixFields
            defaults
            HStack(alignment: .top, spacing: 12) {
                countAs
                quickSearch
            }
            globalVariables
            notes
            footer
        }
        .padding(22)
        .frame(width: 560)
        .onAppear(perform: load)
        .confirmationDialog(adoptTitle, isPresented: $isAskingAboutAffixes) {
            Button("Use as Existing") {
                adoptsAffixes = true
                save()
            }
            Button("Add It Again") {
                adoptsAffixes = false
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every trigger in this set already has it. Using it as the existing one changes nothing in the file. Adding it again rewrites every trigger.")
        }
        .confirmationDialog("Also rename the file?", isPresented: $isAskingAboutFile) {
            Button("Keep File Name") {
                renamesFile = false
                save()
            }
            Button("Rename File") {
                renamesFile = true
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file \((setID as NSString).lastPathComponent) would become \(model.fileName(forSetNamed: name, renaming: setID)). Lines in config files that mention it are updated.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Set Info")
                    .font(.system(size: 13, weight: .bold))
                HStack(spacing: 4) {
                    Text((set?.name ?? "") + " ·")
                    Text(set?.files.first?.path ?? "")
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Tag("YAML", .yaml)
                Text("changes the file")
                Tag("sidecar", .sidecar)
                    .padding(.leading, 6)
                Text("app only")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Name") { Tag("sidecar · name", .sidecar) }
            TextField("", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name")
            Text("Sets the file name when the set is created. Renaming later asks before renaming the file.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var affixFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    label("Prefix") { Tag("rewrites every trigger", .yaml) }
                    TextField("", text: $info.prefix, prompt: Text("None"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Prefix")
                }
                VStack(alignment: .leading, spacing: 6) {
                    label("Suffix") { EmptyView() }
                    TextField("", text: $info.suffix, prompt: Text("None"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Suffix")
                }
            }
            .onChange(of: info.prefix) { _, _ in adoptsAffixes = nil }
            .onChange(of: info.suffix) { _, _ in adoptsAffixes = nil }

            let preview = preview
            if !preview.blockedItems.isEmpty {
                banner(
                    "These items use YAML the form can't change: \(preview.blockedItems.joined(separator: ", ")). "
                        + "Change them on the YAML tab first; until then the prefix and suffix stay as they are.",
                    color: .red
                )
            } else if preview.count > 0 {
                banner(
                    "Triggers become \(preview.examples.joined(separator: " "))"
                        + (preview.count > preview.examples.count ? " …" : "")
                        + (preview.count == 1 ? " It is rewritten on save." : " All \(preview.count) are rewritten in one save."),
                    color: .yellow
                )
            }
        }
    }

    private var defaults: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Default options for new items") { Tag("sidecar · defaults", .sidecar) }
            HStack(spacing: 12) {
                Picker("Case", selection: $info.defaultCase) {
                    Text("Case: Case must match").tag(CaseMode.mustMatch)
                    Text("Case: Case does not matter").tag(CaseMode.insensitive)
                    Text("Case: Case affects expansion").tag(CaseMode.affectsExpansion)
                }
                Picker("Expand", selection: $info.defaultExpand) {
                    Text("Expand: At word break").tag(ExpandMode.wordBreak)
                    Text("Expand: On match").tag(ExpandMode.onMatch)
                }
            }
            .labelsHidden()
            Text("Applied to new items only, including ones made with Quick Define.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var countAs: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Count replacements as") { Tag("sidecar", .sidecar) }
            Picker("Count replacements as", selection: $info.countAs) {
                Text("Expansions").tag(CountAs.expansions)
                Text("Corrections").tag(CountAs.corrections)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickSearch: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Include in Quick Search") { Tag("sidecar", .sidecar) }
            HStack(spacing: 14) {
                Toggle("Abbreviations", isOn: $info.searchAbbreviations)
                Toggle("Expansions", isOn: $info.searchExpansions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var globalVariables: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Global variables · available to every item in this set") { Tag("global_vars", .yaml) }
            let variables = set?.globalVariableList ?? []
            let canEdit = set.map { !$0.isLocked && $0.globalVariablesAreEditable } ?? false
            VStack(spacing: 0) {
                variableRow("Name", "Type", "Value", isHeader: true)
                Divider()
                if variables.isEmpty {
                    Text("This set has no global variables.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(variables.enumerated()), id: \.offset) { position, variable in
                        variableRow(variable.name, variable.type, Self.summary(of: variable), isHeader: false)
                            .background(
                                selectedVariable == variable.name
                                    ? Color.accentColor.opacity(0.22)
                                    : (position % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                selectedVariable = variable.name
                                if canEdit { editVariable(variable) }
                            }
                            .onTapGesture { selectedVariable = variable.name }
                            .accessibilityAddTraits(selectedVariable == variable.name ? .isSelected : [])
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    Menu {
                        Button("Text…") { newVariable("echo") }
                        Button("Date/Time…") { newVariable("date") }
                        Button("Clipboard") { newVariable("clipboard") }
                        Button("Script…") { newVariable("script") }
                        Divider()
                        Button("Choice Dialog…") { newVariable("choice") }
                        Button("Random Text…") { newVariable("random") }
                        Button("Shell Command…") { newVariable("shell") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a global variable")
                    .accessibilityLabel("Add a global variable")
                    Button {
                        guard let name = selectedVariable else { return }
                        saveVariables(variables.filter { $0.name != name })
                        selectedVariable = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedVariable == nil)
                    .help("Remove the selected variable")
                    .accessibilityLabel("Remove the selected variable")
                    Button("Edit…") {
                        if let variable = variables.first(where: { $0.name == selectedVariable }) { editVariable(variable) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedVariable == nil)
                    Spacer()
                    Text(canEdit ? "Use one in an expansion by typing {{name}}." : "Written in a way the app can't change. Edit the file.")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .disabled(!canEdit)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            if let variableError {
                Label(variableError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $variableRequest) { request in
            VariableSheet(
                model: model, request: request, takenNames: Set((set?.globalVariableList ?? []).map(\.name)),
                onSave: { variable in
                    var list = set?.globalVariableList ?? []
                    if let name = request.originalName, let position = list.firstIndex(where: { $0.name == name }) {
                        list[position] = variable
                    } else {
                        list.append(variable)
                    }
                    selectedVariable = variable.name
                    return saveVariables(list)
                }
            )
        }
    }

    /// The one parameter that says most about a variable.
    private static func summary(of variable: SnippetVariable) -> String {
        let parameters = variable.parameters
        for key in ["echo", "format", "cmd", "trigger"] {
            if let value = parameters[key] { return value }
        }
        for key in ["args", "choices", "values"] {
            if let items = variable.params[key]?.list {
                return items.map { $0.text ?? $0.map?["label"]?.text ?? "…" }.joined(separator: key == "args" ? " " : ", ")
            }
        }
        return parameters.values.sorted().first ?? ""
    }

    private func newVariable(_ type: String) {
        let taken = Set((set?.globalVariableList ?? []).map(\.name))
        let name = MatchDraft().uniqueName(SnippetVariable.baseName(forType: type), alsoTaken: taken)
        var variable = SnippetVariable(name: name, type: type)
        if type == "date" { variable.params["format"] = .string("%Y-%m-%d") }
        if type == "echo" { variable.params["echo"] = .string("") }
        if type == "clipboard" {
            saveVariables((set?.globalVariableList ?? []) + [variable])
            selectedVariable = name
        } else {
            variableRequest = VariableRequest(variable: variable, originalName: nil)
        }
    }

    private func editVariable(_ variable: SnippetVariable) {
        variableRequest = VariableRequest(variable: variable, originalName: variable.name)
    }

    /// Global variables are written to the set's file at once, apart from the sheet's OK button.
    @discardableResult
    private func saveVariables(_ variables: [SnippetVariable]) -> String? {
        variableError = model.setGlobalVariables(variables, inSet: setID)
        return variableError
    }

    private func variableRow(_ name: String, _ type: String, _ value: String, isHeader: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(width: 110, alignment: .leading)
            Text(type).frame(width: 80, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(isHeader ? .system(size: 11, weight: .semibold) : .system(size: 12, design: .monospaced))
        .foregroundStyle(isHeader ? .secondary : .primary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Notes") { Tag("sidecar · notes", .sidecar) }
            TextEditor(text: $info.notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(height: 46)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Notes")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Sidecar:")
                Text(".abbrio/metadata.json")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !preview.blockedItems.isEmpty)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func label(_ title: String, @ViewBuilder tag: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            tag()
        }
        // The same height with or without a tag, so fields in neighbouring columns line up.
        .frame(height: 18)
    }

    private func banner(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.55)))
    }

    private var adoptTitle: String {
        guard let set else { return "" }
        let prefixIsNew = info.prefix != set.info.prefix
        let part = prefixIsNew ? info.prefix : info.suffix
        return "Triggers already \(prefixIsNew ? "start" : "end") with \u{201C}\(part)\u{201D}"
    }

    // MARK: Actions

    private func load() {
        guard !hasLoaded, let set else { return }
        hasLoaded = true
        name = set.name
        info = set.info
    }

    private func save() {
        guard let set else { return dismiss() }
        let preview = preview
        if preview.canAdopt, adoptsAffixes == nil {
            isAskingAboutAffixes = true
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != set.name, model.renameWouldChangeFile(setID, to: trimmed), renamesFile == nil {
            switch model.preferences.renameFilePolicy {
            case .ask:
                isAskingAboutFile = true
                return
            case .always: renamesFile = true
            case .never: renamesFile = false
            }
        }
        error = model.applySetInfo(
            info, name: trimmed, to: setID,
            adoptingAffixes: preview.canAdopt && adoptsAffixes == true,
            renamingFile: renamesFile == true
        )
        if error == nil { dismiss() }
    }
}
