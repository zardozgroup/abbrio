import SwiftUI
import UniformTypeIdentifiers
import SnippetModel

/// The expansion part of the details pane: its type, the Insert menu, the editor with chips, and what
/// goes with each type (a preview, a picture, the form Espanso will show).
struct ExpansionSection: View {
    @Bindable var model: AppModel
    let snippet: Snippet

    @State private var proxy = ExpansionEditorProxy()
    @State private var variableRequest: VariableRequest?
    @State private var fieldRequest: FieldRequest?
    @State private var newFieldRequest: FieldRequest?
    @State private var isConfirmingPicture = false
    @State private var referencesOriginal = false
    @State private var isTargeted = false
    @State private var editorHeight: CGFloat = 110
    @State private var pictureThumbnail = PicturePreview.none

    private var draft: MatchDraft { model.draft ?? MatchDraft(snippet) }
    private var isLocked: Bool { model.formLockReason != nil }
    private var kind: ExpansionKind { draft.expansion.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if draft.isRegex, kind != .picture, !model.regexGroupNames.isEmpty {
                RegexGroupBar(names: model.regexGroupNames, isDisabled: isLocked, insert: insert)
            }
            switch kind {
            case .picture:
                pictureWell
            case .text:
                editor(isMonospaced: false)
            case .markdown, .html:
                editor(isMonospaced: true)
                preview
            }
            ForEach(draft.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if draft.hasCursor {
                HStack(spacing: 6) {
                    Tag("$|$", .yaml)
                    Text("The cursor chip is saved as this marker. One per item.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let preview = snippet.casePreview {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if kind != .picture, !draft.formFieldList.isEmpty {
                FormPreview(draft: draft)
            }
        }
        .sheet(item: $variableRequest) { request in
            VariableSheet(
                model: model, request: request, takenNames: takenVariableNames,
                onSave: { save($0, for: request) },
                onRemove: request.originalName.map { name in { model.removeVariable(named: name) } }
            )
        }
        .sheet(item: $newFieldRequest) { request in
            FieldEditor(
                request: request, takenNames: Set(draft.formFieldNames),
                supportsSeveralChoices: model.engineVersion?.supportsListSeparator ?? true,
                onSave: { field in
                    if let token = model.addFormField(field) { insert(token) }
                }
            )
        }
        .confirmationDialog("Switch this item to a picture?", isPresented: $isConfirmingPicture) {
            Button("Switch to Picture") { model.setKind(.picture) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A picture item has no text. The text and its dynamic content are put aside and come back if you switch the type back before selecting another item. Undo also restores them.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Expansion")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            ExpansionTypeBar(selected: kind) { choice in
                if choice == .picture, model.switchingToPictureDiscardsContent {
                    isConfirmingPicture = true
                } else {
                    model.setKind(choice)
                }
            }
            .disabled(isLocked)
            insertMenu
        }
    }

    private var insertMenu: some View {
        Menu {
            Button("Cursor Position") { insert("$|$") }
                .disabled(draft.hasCursor)
            Button("Clipboard") {
                let variable = SnippetVariable(name: model.uniqueVariableName("clip"), type: "clipboard")
                if let token = model.addVariable(variable) { insert(token) }
            }
            Button("Date/Time…") {
                request("date", [ParamEntry("format", .string("%A, %B %e, %Y"))])
            }
            Button("Input Field…") { requestField(.text) }
            Button("Pop-up Menu…") { requestField(.choice) }
            Button("Insert Abbreviation…") { request("match", []) }
            Button("Script…") { request("script", []) }
            Divider()
            Section("Espanso extras") {
                Button("Choice Dialog…") { request("choice", []) }
                Button("Random Text…") { request("random", []) }
                Button("Shell Command…") { request("shell", []) }
            }
            Divider()
            Button("Global Variables…") {
                if let id = model.selectedSnippetID, let set = model.set(containing: id) {
                    model.showSetInfo(for: set.id)
                }
            }
        } label: {
            Text("{…} Insert")
                .font(.system(size: 12))
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .disabled(isLocked || kind == .picture)
        .help("Insert dynamic content at the insertion point")
    }

    private var takenVariableNames: Set<String> {
        Set(draft.variables.map(\.name)).union(model.editingGlobalVariables.map(\.name))
    }

    private func request(_ type: String, _ params: [ParamEntry]) {
        let name = model.uniqueVariableName(SnippetVariable.baseName(forType: type))
        variableRequest = VariableRequest(variable: SnippetVariable(name: name, type: type, params: params), originalName: nil)
    }

    private func requestField(_ kind: FormField.Kind) {
        let name = draft.uniqueName("field")
        // The short form syntax has no labels: its text is the form.
        let label = draft.isShortForm ? nil : ExpansionPreview.humanized(name)
        newFieldRequest = FieldRequest(field: FormField(name: name, label: label, kind: kind), originalName: nil)
    }

    private func save(_ variable: SnippetVariable, for request: VariableRequest) -> String? {
        if let name = request.originalName {
            model.updateVariable(named: name, to: variable)
        } else if let token = model.addVariable(variable) {
            insert(token)
        } else {
            return "This item can't be changed."
        }
        return nil
    }

    /// Puts text in at the insertion point, or at the end when the text box has none.
    private func insert(_ token: String) {
        if !proxy.insert(token) {
            model.setBody(draft.body + token)
        }
        model.commitDraft()
    }

    // MARK: Editor

    private func editor(isMonospaced: Bool) -> some View {
        ExpansionEditor(
            text: draft.body,
            isShortForm: draft.isShortForm,
            isMonospaced: isMonospaced,
            isEditable: !isLocked,
            signature: chipSignature,
            style: chipStyle,
            proxy: proxy,
            onChange: { model.setBody($0) },
            onChipClick: clicked,
            onEndEditing: { model.commitDraft() },
            onHeightChange: { editorHeight = $0 }
        )
        .frame(height: min(max(editorHeight, 110), 280))
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .popover(
            item: $fieldRequest, attachmentAnchor: .rect(.rect(fieldRequest?.anchor ?? .zero)), arrowEdge: .bottom
        ) { request in
            FieldEditor(
                request: request,
                takenNames: Set(draft.formFieldNames),
                supportsSeveralChoices: model.engineVersion?.supportsListSeparator ?? true,
                onSave: { field in
                    if let name = request.originalName { model.updateFormField(named: name, to: field) }
                },
                onRemove: isLocked ? nil : request.originalName.map { name in { model.removeFormField(named: name) } }
            )
        }
    }

    private func clicked(_ piece: ExpansionPiece, at rect: CGRect) {
        guard !isLocked else { return }
        switch piece.kind {
        case .field(let name):
            openField(name, at: rect)
        case .variable(let name, let field):
            if let field {
                guard draft.formVariableIndex.map({ draft.variables[$0].name }) == name else { return }
                openField(field, at: rect)
            } else if let variable = draft.variables.first(where: { $0.name == name }), variable.type != "form" {
                variableRequest = VariableRequest(variable: variable, originalName: name)
            }
        case .cursor, .text:
            break
        }
    }

    private func openField(_ name: String, at rect: CGRect) {
        guard let field = draft.formField(named: name) else { return }
        fieldRequest = FieldRequest(field: field, originalName: name, anchor: rect)
    }

    /// Changes whenever a chip might need another title.
    private var chipSignature: Int {
        var hasher = Hasher()
        hasher.combine(draft.variables)
        hasher.combine(draft.formFields)
        hasher.combine(model.editingGlobalVariables)
        hasher.combine(model.regexGroupNames)
        hasher.combine(Calendar.current.startOfDay(for: Date()))
        return hasher.finalize()
    }

    private func chipStyle(_ piece: ExpansionPiece) -> ChipStyle {
        switch piece.kind {
        case .cursor, .text:
            return ChipStyle(title: "Cursor", symbol: "character.cursor.ibeam", tone: .cursor, help: "Where the cursor ends up")
        case .field(let name):
            return fieldStyle(name)
        case .variable(let name, let field):
            if let field {
                if draft.formVariableIndex.map({ draft.variables[$0].name }) == name { return fieldStyle(field) }
                return ChipStyle(title: "\(name).\(field)", symbol: "questionmark.circle", tone: .unknown, help: "No form named \(name)")
            }
            if let variable = draft.variables.first(where: { $0.name == name }) {
                return variableStyle(variable, isGlobal: false)
            }
            if model.regexGroupNames.contains(name) {
                return ChipStyle(title: name, symbol: "parentheses", tone: .variable, help: "What the group \(name) of the pattern matched")
            }
            if let variable = model.editingGlobalVariables.first(where: { $0.name == name }) {
                return variableStyle(variable, isGlobal: true)
            }
            return ChipStyle(title: name, symbol: "questionmark.circle", tone: .unknown, help: "No variable named \(name) in this item or its set")
        }
    }

    private func fieldStyle(_ name: String) -> ChipStyle {
        let field = draft.formField(named: name)
        let title = field?.label.flatMap { $0.isEmpty ? nil : $0 } ?? ExpansionPreview.humanized(name)
        let isMenu = field.map { $0.kind != .text } ?? false
        return ChipStyle(
            title: title, symbol: isMenu ? "list.bullet" : "character.textbox", tone: .field,
            help: (isMenu ? "Pop-up menu " : "Input field ") + name
        )
    }

    private func variableStyle(_ variable: SnippetVariable, isGlobal: Bool) -> ChipStyle {
        let parameters = variable.parameters
        var title: String
        var symbol: String
        switch variable.type {
        case "date":
            title = ExpansionPreview.renderedDate(
                format: parameters["format"] ?? "%Y-%m-%d", offset: TimeInterval(parameters["offset"] ?? "") ?? 0,
                locale: parameters["locale"],
                timeZone: parameters["tz"].flatMap(TimeZone.init(identifier:)) ?? .current, now: Date()
            )
            symbol = "calendar"
        case "clipboard":
            (title, symbol) = ("Clipboard", "doc.on.clipboard")
        case "match":
            (title, symbol) = (parameters["trigger"] ?? "Abbreviation", "arrow.turn.down.right")
        case "script":
            (title, symbol) = ("Script", "scroll")
        case "shell":
            (title, symbol) = ("Shell", "terminal")
        case "choice":
            (title, symbol) = ("Choice", "list.bullet.rectangle")
        case "random":
            (title, symbol) = ("Random", "dice")
        case "echo":
            (title, symbol) = (parameters["echo"] ?? variable.name, "textformat")
        case "form":
            (title, symbol) = ("Form", "list.bullet.rectangle")
        default:
            (title, symbol) = (variable.name, "curlybraces")
        }
        if title.count > 28 { title = String(title.prefix(27)) + "…" }
        return ChipStyle(
            title: title, symbol: symbol, tone: .variable,
            help: (isGlobal ? "Global variable " : "Variable ") + variable.name + ", " + variable.type
        )
    }

    // MARK: Markdown and HTML

    /// The text with each chip replaced by its title, for the preview.
    private var previewText: String {
        draft.pieces.map { piece -> String in
            switch piece.kind {
            case .text: return piece.source
            case .cursor: return ""
            default: return "{" + chipStyle(piece).title + "}"
            }
        }.joined()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Group {
                if kind == .markdown {
                    ScrollView {
                        MarkdownPreview(text: previewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                } else {
                    HTMLPreview(html: previewText)
                }
            }
            .frame(height: 110)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            Text(kind == .markdown
                ? "An approximation. Espanso converts the Markdown itself when the abbreviation expands."
                : "An approximation. Scripts and anything loaded from the network are left out here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Picture

    private var picturePath: String { draft.expansion.body }

    private var pictureWell: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    switch pictureThumbnail {
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                    case .loaded(let image):
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                    case .none, .failed:
                        Image(systemName: picturePath.isEmpty ? "photo.badge.plus" : "photo.badge.exclamationmark")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 72)
                .task(id: picturePath) { await loadPreview() }

                VStack(alignment: .leading, spacing: 4) {
                    if picturePath.isEmpty {
                        Text("Drop a picture here")
                            .font(.system(size: 13))
                        Text("or choose a file.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text((picturePath as NSString).lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(picturePath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if case .failed(let problem) = pictureThumbnail {
                            Label(problem == .missing ? "The file is not there." : "This picture can't be previewed.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    Button(picturePath.isEmpty ? "Choose…" : "Replace…") { choosePicture() }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: picturePath.isEmpty ? [5, 4] : [])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard !isLocked, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in usePicture(url) }
                }
                return true
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Picture")

            Toggle("Reference original file", isOn: $referencesOriginal)
                .font(.system(size: 12))
                .help("Off: the picture is copied into the Espanso folder's images folder and the original is left untouched. On: the item points at the file where it is, and stops working if the file is moved.")
            Text(referencesOriginal
                ? "The next picture you choose is used where it is. Nothing is copied."
                : "The next picture you choose is copied into the Espanso folder's images folder. Later changes to the original don't reach the copy.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Tag("image_path", .yaml)
                Text("Pictures are never deleted by the app, because other items may use them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(isLocked)
    }

    /// Loads the preview off the main actor. The stored path is only read, never changed.
    private func loadPreview() async {
        guard let url = model.pictureURL(forPath: picturePath) else {
            pictureThumbnail = .none
            return
        }
        pictureThumbnail = .loading
        let result = await PictureLoader.thumbnail(for: url)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let image): pictureThumbnail = .loaded(image)
        case .failure(let problem): pictureThumbnail = .failed(problem)
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = referencesOriginal
            ? "Choose a picture. The item will point at the file where it is."
            : "Choose a picture. It is copied into the Espanso folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        usePicture(url)
    }

    /// The file itself is checked by the model before anything is copied or saved.
    private func usePicture(_ url: URL) {
        let referencingOriginal = referencesOriginal
        Task { await model.setPicture(from: url, referencingOriginal: referencingOriginal) }
    }
}

/// What the picture well shows on the left.
private enum PicturePreview {
    /// No picture is chosen yet.
    case none
    case loading
    case loaded(CGImage)
    case failed(PictureProblem)
}

/// Text, Markdown, HTML and Picture.
private struct ExpansionTypeBar: View {
    let selected: ExpansionKind
    let choose: (ExpansionKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ExpansionKind.allCases, id: \.self) { kind in
                Button {
                    choose(kind)
                } label: {
                    Text(kind.rawValue)
                        .font(.system(size: 12, weight: kind == selected ? .semibold : .regular))
                        .foregroundStyle(kind == selected ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                            if kind == selected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Expansion type")
    }
}

/// What Espanso shows when an item with a form expands.
private struct FormPreview: View {
    let draft: MatchDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(writes)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Form preview: what Espanso shows on expand")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Tag(draft.isShortForm ? "form" : "type: form · layout", .yaml)
                }
                VStack(alignment: .leading, spacing: 7) {
                    if draft.isShortForm {
                        shortLayout
                    } else {
                        ForEach(draft.formFieldList, id: \.name) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text((field.label ?? ExpansionPreview.humanized(field.name)) + ":")
                                    .frame(minWidth: 70, alignment: .leading)
                                control(for: field)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Text("Submit")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                    }
                }
                .font(.system(size: 12))
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                Text(draft.isShortForm
                    ? "This item uses the short form syntax: its whole text is the form."
                    : "The layout holds only the labelled fields, not the whole expansion.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private var writes: String {
        let key = draft.isShortForm ? "form" : (draft.expansion.kind == .text ? "replace" : draft.expansion.kind.rawValue.lowercased())
        let line = draft.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return "Writes \(key): \"\(line)\""
    }

    /// The short form shows its text with the fields in place.
    private var shortLayout: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(draft.body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    ForEach(Array(ExpansionPiece.pieces(of: line, isShortForm: true).enumerated()), id: \.offset) { _, piece in
                        if case .field(let name) = piece.kind, let field = draft.formField(named: name) {
                            control(for: field)
                        } else {
                            Text(piece.source)
                        }
                    }
                }
            }
        }
    }

    private func control(for field: FormField) -> some View {
        HStack(spacing: 4) {
            Text(field.defaultValue.isEmpty ? " " : field.defaultValue)
                .lineLimit(1)
                .frame(minWidth: 90, maxWidth: field.kind == .text ? .infinity : nil, alignment: .leading)
            if field.kind != .text {
                Image(systemName: field.kind == .choice ? "chevron.up.chevron.down" : "list.bullet")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, field.kind == .text && field.isMultiline ? 9 : 2)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
