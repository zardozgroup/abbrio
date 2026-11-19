import SwiftUI
import ConfigStore
import SnippetModel

/// A variable being added or changed in a sheet.
nonisolated struct VariableRequest: Identifiable {
    let id = UUID()
    var variable: SnippetVariable
    /// The variable's name before the sheet opened. Nil for one that is being added.
    var originalName: String?
}

/// The sheet for one variable: Date/Time, Insert Abbreviation, Script, Shell Command, Choice Dialog,
/// Random Text, or a fixed text for a global variable.
struct VariableSheet: View {
    let model: AppModel
    let request: VariableRequest
    /// Names the variable may not take.
    let takenNames: Set<String>
    /// Saves the variable. Returns a message when it could not be saved.
    let onSave: (SnippetVariable) -> String?
    let onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var variable: SnippetVariable
    @State private var script = ""
    @State private var language = ScriptLanguage.appleScript
    @State private var testOutput: String?
    @State private var isTesting = false
    @State private var error: String?
    @State private var search = ""

    init(
        model: AppModel, request: VariableRequest, takenNames: Set<String>,
        onSave: @escaping (SnippetVariable) -> String?, onRemove: (() -> Void)? = nil
    ) {
        self.model = model
        self.request = request
        self.takenNames = takenNames
        self.onSave = onSave
        self.onRemove = onRemove
        _variable = State(initialValue: request.variable)
    }

    private var isNew: Bool { request.originalName == nil }

    private var title: String {
        let name: String
        switch variable.type {
        case "date": name = "Date/Time"
        case "match": name = "Abbreviation"
        case "script": name = "Script"
        case "shell": name = "Shell Command"
        case "choice": name = "Choice Dialog"
        case "random": name = "Random Text"
        case "clipboard": name = "Clipboard"
        case "echo": name = "Text"
        default: name = "Variable"
        }
        return (isNew ? "Insert " : "Edit ") + name
    }

    private var isSupported: Bool {
        if variable.type == "script" {
            return isNew || model.scriptFile(of: request.variable) != nil
        }
        return ["date", "match", "shell", "choice", "random", "clipboard", "echo"].contains(variable.type)
    }

    private var nameProblem: String? {
        if !MatchDraft.isValidName(variable.name) {
            return "Use only letters, numbers and underscores."
        }
        if variable.name != request.originalName, takenNames.contains(variable.name) {
            return "Another variable has this name."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            if isSupported {
                content
            } else {
                Text("This variable is written in a way the form doesn't cover. Change it on the YAML tab.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SheetField("Variable name", tag: "name") {
                TextField("", text: $variable.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .disabled(!isSupported)
                if let nameProblem {
                    SheetNote(nameProblem, color: .red)
                }
            }

            SheetField(isSupported ? "Writes to vars:" : "Written as:") {
                YAMLBox(text: YAMLPreview.text(for: previewVariable))
            }

            if let error {
                SheetNote(error, color: .red)
            }

            HStack {
                if let onRemove {
                    Button("Remove", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Insert" : "Done") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isSupported || nameProblem != nil || contentProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            if variable.type == "script" {
                if let file = model.scriptFile(of: request.variable) { language = file.language }
                script = model.scriptCode(of: request.variable) ?? ""
            }
        }
    }

    /// The variable as it would be written, for the preview. A script's file name is settled on saving.
    private var previewVariable: SnippetVariable {
        guard variable.type == "script", isSupported else { return variable }
        var preview = variable
        let path = model.scriptFile(of: request.variable).flatMap { $0.language == language ? $0.path : nil }
            ?? AppModel.scriptsFolder + "/" + variable.name + "." + language.fileExtension
        preview.params["args"] = .list((language.interpreter + ["%CONFIG%/" + path]).map(ParamValue.string))
        return preview
    }

    private var contentProblem: String? {
        switch variable.type {
        case "date": return text("format").isEmpty ? "Enter a format." : nil
        case "match": return text("trigger").isEmpty ? "Choose an abbreviation." : nil
        case "shell": return text("cmd").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a command." : nil
        case "script": return script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a script." : nil
        case "choice": return choiceRows.isEmpty ? "Add at least one value." : nil
        case "random": return strings("choices").isEmpty ? "Add at least one alternative." : nil
        default: return nil
        }
    }

    private func save() {
        var result = variable
        if result.type == "script" {
            guard let saved = model.saveScript(script, language: language, for: result) else {
                error = "The script could not be saved."
                return
            }
            result = saved
        }
        if let message = onSave(result) {
            error = message
        } else {
            dismiss()
        }
    }

    // MARK: Parameters

    private func text(_ key: String) -> String {
        variable.params[key]?.text ?? ""
    }

    private func textBinding(_ key: String, removingWhenEmpty: Bool = true) -> Binding<String> {
        Binding(
            get: { text(key) },
            set: { variable.params[key] = $0.isEmpty && removingWhenEmpty ? nil : .string($0) }
        )
    }

    private func strings(_ key: String) -> [String] {
        variable.params[key]?.list?.compactMap(\.text) ?? []
    }

    private func stringsBinding(_ key: String) -> Binding<[String]> {
        Binding(
            get: { strings(key) },
            set: { variable.params[key] = .list($0.map(ParamValue.string)) }
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch variable.type {
        case "date":
            DateForm(variable: $variable, supportsTimeZone: model.engineVersion?.supportsDateTimeZone ?? true)
        case "match":
            matchPicker
        case "script":
            scriptEditor
        case "shell":
            shellEditor
        case "choice":
            SheetField("Values · the label is shown, the inserted text is typed", tag: "values") {
                ChoiceList(rows: Binding(get: { choiceRows }, set: { setChoiceRows($0) }))
            }
        case "random":
            SheetField("Alternatives · one is picked each time", tag: "choices") {
                StringList(items: stringsBinding("choices"), prompt: "Add an alternative")
            }
        case "echo":
            SheetField("Text", tag: "echo") {
                TextField("", text: textBinding("echo", removingWhenEmpty: false))
                    .textFieldStyle(.roundedBorder)
            }
        default:
            Text("Inserts what is on the clipboard when the abbreviation expands.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var matchPicker: some View {
        SheetField("Abbreviation to insert", tag: "trigger") {
            TextField("", text: $search, prompt: Text("Search abbreviations"))
                .textFieldStyle(.roundedBorder)
            let choices = model.triggerChoices.filter { choice in
                search.isEmpty || choice.trigger.localizedCaseInsensitiveContains(search)
                    || choice.detail.localizedCaseInsensitiveContains(search)
            }
            List(choices, selection: Binding(
                get: { choices.first { $0.trigger == text("trigger") }?.id },
                set: { id in
                    if let choice = choices.first(where: { $0.id == id }) {
                        variable.params["trigger"] = .string(choice.trigger)
                    }
                }
            )) { choice in
                HStack(spacing: 8) {
                    Text(choice.trigger)
                        .font(.system(size: 12, design: .monospaced))
                    Text(choice.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(choice.setName)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
            }
            .listStyle(.bordered)
            .frame(height: 170)
            if !text("trigger").isEmpty {
                Text("Inserts the expansion of \(text("trigger")).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetField("Language", tag: "args") {
                Picker("Language", selection: $language) {
                    ForEach(ScriptLanguage.allCases) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SheetField("Script · what it returns is inserted") {
                CodeBox(text: $script, height: 130)
            }
            testRow {
                await model.testScript(script, language: language)
            }
            Text("The script is kept as a file in the Espanso folder's scripts folder and runs with osascript.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shellEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetField("Command · what it prints is inserted", tag: "cmd") {
                CodeBox(text: textBinding("cmd", removingWhenEmpty: false), height: 80)
            }
            testRow {
                await model.testShellCommand(text("cmd"))
            }
        }
    }

    private func testRow(_ run: @escaping () async -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            testControls(run)
            Text("Test runs this code with your permissions and can change files or access the network.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func testControls(_ run: @escaping () async -> String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button("Test") {
                isTesting = true
                testOutput = nil
                Task {
                    testOutput = await run()
                    isTesting = false
                }
            }
            .disabled(isTesting || contentProblem != nil)
            .help("Runs it now on this Mac and shows what it returns")
            if isTesting {
                ProgressView().controlSize(.small)
            }
            if let testOutput {
                Text(testOutput)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Choice values

    private var choiceRows: [ChoiceRow] {
        (variable.params["values"]?.list ?? []).compactMap { value in
            if let text = value.text { return ChoiceRow(label: text, inserted: "") }
            guard let entries = value.map, let label = entries["label"]?.text else { return nil }
            return ChoiceRow(label: label, inserted: entries["id"]?.text ?? "")
        }
    }

    private func setChoiceRows(_ rows: [ChoiceRow]) {
        variable.params["values"] = .list(rows.map { row in
            row.inserted.isEmpty
                ? .string(row.label)
                : .map([ParamEntry("label", .string(row.label)), ParamEntry("id", .string(row.inserted))])
        })
    }
}

// MARK: - Date/Time

/// The fields of the Date/Time sheet, with a live preview.
private struct DateForm: View {
    @Binding var variable: SnippetVariable
    let supportsTimeZone: Bool

    private static let presets = ["%b %e, %Y", "%m/%d/%Y", "%Y-%m-%d", "%A, %B %e, %Y", "%I:%M %p"]
    private static let pieces: [(String, String)] = [
        ("Weekday", "%A"), ("Month", "%B"), ("Day", "%e"), ("Year", "%Y"), ("Hour", "%H"), ("Minute", "%M"), ("AM/PM", "%p"),
    ]
    private static let locales: [(tag: String, name: String)] = {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for identifier in Locale.availableIdentifiers {
            let parts = identifier.split(separator: "_")
            // Language and region only, which is what Espanso's locale names look like.
            guard parts.count == 2, parts[1].count == 2, let name = Locale.current.localizedString(forIdentifier: identifier) else { continue }
            let tag = parts.joined(separator: "-")
            if seen.insert(tag).inserted { result.append((tag, name)) }
        }
        return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }()
    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    @State private var isCustom = false

    private var format: String { variable.params["format"]?.text ?? "" }
    private var offset: Int { variable.params["offset"]?.int ?? Int(variable.params["offset"]?.text ?? "") ?? 0 }
    private var locale: String? { variable.params["locale"]?.text }
    private var zone: String? { variable.params["tz"]?.text }

    private func setFormat(_ value: String) {
        variable.params["format"] = .string(value)
    }

    private func setOffset(days: Int, hours: Int) {
        let seconds = days * 86400 + hours * 3600
        variable.params["offset"] = seconds == 0 ? nil : .int(seconds)
    }

    private func rendered(_ format: String, offset: Int, now: Date) -> String {
        ExpansionPreview.renderedDate(
            format: format, offset: TimeInterval(offset), locale: locale,
            timeZone: zone.flatMap(TimeZone.init(identifier:)) ?? .current, now: now
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            form(now: timeline.date)
        }
        .onAppear { isCustom = !Self.presets.contains(format) }
    }

    private func form(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Live preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(format.isEmpty ? " " : rendered(format, offset: offset, now: now))
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(caption(now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .accessibilityElement(children: .combine)

            SheetField("Format presets") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                    ForEach(Self.presets, id: \.self) { preset in
                        presetButton(
                            title: rendered(preset, offset: 0, now: now), detail: preset,
                            isOn: !isCustom && format == preset
                        ) {
                            isCustom = false
                            setFormat(preset)
                        }
                    }
                    presetButton(title: "Custom…", detail: "", isOn: isCustom) { isCustom = true }
                }
            }

            SheetField("Format (strftime)", tag: "format") {
                TextField("", text: Binding(get: { format }, set: { value in
                    setFormat(value)
                    isCustom = !Self.presets.contains(value)
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                HStack(spacing: 4) {
                    ForEach(Self.pieces, id: \.1) { name, code in
                        Button {
                            setFormat(format + code)
                            isCustom = !Self.presets.contains(format)
                        } label: {
                            HStack(spacing: 3) {
                                Text(name)
                                Text(code).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11))
                        }
                        .controlSize(.small)
                        .help("Adds \(code) to the format")
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                SheetField("Offset", tag: offset == 0 ? "no offset" : "offset: \(offset)") {
                    HStack(spacing: 6) {
                        NumberField(value: Binding(get: { offset / 86400 }, set: { setOffset(days: $0, hours: (offset % 86400) / 3600) }), label: "Days")
                        Text("days")
                        NumberField(value: Binding(get: { (offset % 86400) / 3600 }, set: { setOffset(days: offset / 86400, hours: $0) }), label: "Hours")
                        Text("hours")
                    }
                    .font(.system(size: 13))
                }
                SheetField("Locale", tag: "locale") {
                    Picker("Locale", selection: Binding(get: { locale }, set: { variable.params["locale"] = $0.map(ParamValue.string) })) {
                        Text("Same as the system").tag(String?.none)
                        Divider()
                        if let locale, !Self.locales.contains(where: { $0.tag == locale }) {
                            Text(locale).tag(String?.some(locale))
                        }
                        ForEach(Self.locales, id: \.tag) { item in
                            Text("\(item.name) · \(item.tag)").tag(String?.some(item.tag))
                        }
                    }
                    .labelsHidden()
                }
            }

            SheetField(supportsTimeZone ? "Time zone · Espanso 2.3+" : "Time zone · needs Espanso 2.3 or later", tag: "tz") {
                Picker("Time zone", selection: Binding(get: { zone }, set: { variable.params["tz"] = $0.map(ParamValue.string) })) {
                    Text("Same as the system").tag(String?.none)
                    Divider()
                    if let zone, !Self.zones.contains(zone) {
                        Text(zone).tag(String?.some(zone))
                    }
                    ForEach(Self.zones, id: \.self) { zone in
                        Text(zone).tag(String?.some(zone))
                    }
                }
                .labelsHidden()
                .disabled(!supportsTimeZone && zone == nil)
            }
        }
    }

    private func caption(now: Date) -> String {
        let moment = now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
        guard offset != 0 else { return "If expanded now (\(moment))" }
        let days = offset / 86400, hours = (offset % 86400) / 3600
        var parts: [String] = []
        if days != 0 { parts.append("\(days > 0 ? "+" : "")\(days) day") }
        if hours != 0 { parts.append("\(hours > 0 ? "+" : "")\(hours) hour") }
        return "If expanded now (\(moment)) with a \(parts.joined(separator: " ")) offset"
    }

    private func presetButton(title: String, detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small box for a whole number, which may be negative.
private struct NumberField: View {
    @Binding var value: Int
    let label: String

    var body: some View {
        TextField("", value: $value, format: .number.sign(strategy: .always(includingZero: false)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            .accessibilityLabel(label)
    }
}

// MARK: - Building blocks

/// A labelled part of a sheet, with the YAML key it writes shown on the right.
struct SheetField<Content: View>: View {
    let title: String
    let tag: String?
    let content: Content

    init(_ title: String, tag: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tag = tag
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let tag { Tag(tag, .yaml) }
            }
            .frame(minHeight: 18)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SheetNote: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// YAML shown as it will be written.
struct YAMLBox: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 130)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A monospaced text box for a script or a command.
struct CodeBox: View {
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A list of short texts that can be added to and removed from.
struct StringList: View {
    @Binding var items: [String]
    let prompt: String
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                HStack(spacing: 6) {
                    TextField("", text: Binding(
                        get: { item },
                        set: { if items.indices.contains(position) { items[position] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        if items.indices.contains(position) { items.remove(at: position) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(item)")
                }
            }
            TextField("", text: $entry, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
        }
        .font(.system(size: 13))
    }

    private func add() {
        guard !entry.isEmpty else { return }
        items.append(entry)
        entry = ""
    }
}

nonisolated struct ChoiceRow: Hashable {
    var label: String
    /// The text inserted when the label is chosen. Empty inserts the label itself.
    var inserted: String
}

/// The values of a choice dialog: a label, and optionally other text to insert.
private struct ChoiceList: View {
    @Binding var rows: [ChoiceRow]
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { position, row in
                HStack(spacing: 6) {
                    TextField("", text: Binding(
                        get: { row.label },
                        set: { value in change(position) { $0.label = value } }
                    ), prompt: Text("Label"))
                    TextField("", text: Binding(
                        get: { row.inserted },
                        set: { value in change(position) { $0.inserted = value } }
                    ), prompt: Text("Inserts the label"))
                    Button {
                        var copy = rows
                        if copy.indices.contains(position) { copy.remove(at: position) }
                        rows = copy
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(row.label)")
                }
                .textFieldStyle(.roundedBorder)
            }
            TextField("", text: $entry, prompt: Text("Add a value"))
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !entry.isEmpty else { return }
                    rows = rows + [ChoiceRow(label: entry, inserted: "")]
                    entry = ""
                }
        }
        .font(.system(size: 13))
    }

    private func change(_ position: Int, _ edit: (inout ChoiceRow) -> Void) {
        var copy = rows
        guard copy.indices.contains(position) else { return }
        edit(&copy[position])
        rows = copy
    }
}
