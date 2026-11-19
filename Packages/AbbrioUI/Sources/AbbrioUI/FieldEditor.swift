import SwiftUI
import SnippetModel

/// A form field being added or changed.
nonisolated struct FieldRequest: Identifiable {
    let id = UUID()
    var field: FormField
    /// The field's name before the editor opened. Nil for one that is being added.
    var originalName: String?
    /// Where the field's chip is in the editor, for the popover's arrow.
    var anchor: CGRect = .zero
}

/// The small editor for one field of a form: an input field or a pop-up menu.
struct FieldEditor: View {
    let request: FieldRequest
    /// Names the field may not take.
    let takenNames: Set<String>
    let supportsSeveralChoices: Bool
    let onSave: (FormField) -> Void
    let onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var field: FormField

    init(
        request: FieldRequest, takenNames: Set<String>, supportsSeveralChoices: Bool,
        onSave: @escaping (FormField) -> Void, onRemove: (() -> Void)? = nil
    ) {
        self.request = request
        self.takenNames = takenNames
        self.supportsSeveralChoices = supportsSeveralChoices
        self.onSave = onSave
        self.onRemove = onRemove
        _field = State(initialValue: request.field)
    }

    private var isMenu: Bool { field.kind != .text }

    private var nameProblem: String? {
        if !MatchDraft.isValidName(field.name) { return "Use only letters, numbers and underscores." }
        if field.name != request.originalName, takenNames.contains(field.name) { return "Another field has this name." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isMenu ? "Pop-up Menu" : "Input Field")
                .font(.system(size: 13, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    rowLabel("Name")
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("", text: $field.name)
                            .font(.system(size: 13, design: .monospaced))
                            .autocorrectionDisabled()
                            .accessibilityLabel("Name")
                        if let nameProblem { SheetNote(nameProblem, color: .red) }
                    }
                }
                if field.label != nil {
                    GridRow {
                        rowLabel("Label")
                        TextField("", text: Binding(get: { field.label ?? "" }, set: { field.label = $0 }))
                            .accessibilityLabel("Label")
                    }
                }
                if isMenu {
                    GridRow(alignment: .top) {
                        rowLabel("Values")
                        HStack(alignment: .top) {
                            StringList(items: $field.values, prompt: "Add a value")
                            Tag("values", .yaml)
                        }
                    }
                    GridRow {
                        rowLabel("Default")
                        HStack {
                            Picker("Default", selection: $field.defaultValue) {
                                Text("None").tag("")
                                ForEach(field.values, id: \.self) { Text($0).tag($0) }
                                if !field.defaultValue.isEmpty, !field.values.contains(field.defaultValue) {
                                    Text(field.defaultValue).tag(field.defaultValue)
                                }
                            }
                            .labelsHidden()
                            Tag("default", .yaml)
                        }
                    }
                    GridRow {
                        rowLabel("Choose")
                        HStack {
                            Picker("Choose", selection: $field.kind) {
                                Text("One").tag(FormField.Kind.choice)
                                Text("Several").tag(FormField.Kind.list)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Tag("type: \(field.kind.rawValue)", .yaml)
                        }
                    }
                    if field.kind == .list {
                        GridRow {
                            rowLabel("Join with")
                            HStack {
                                TextField("", text: Binding(
                                    get: { field.separator ?? "" },
                                    set: { field.separator = $0.isEmpty ? nil : $0 }
                                ), prompt: Text(", "))
                                .frame(width: 70)
                                .disabled(!supportsSeveralChoices)
                                .accessibilityLabel("Join with")
                                Tag("separator", .yaml)
                            }
                        }
                    }
                } else {
                    GridRow {
                        rowLabel("Default")
                        HStack {
                            TextField("", text: $field.defaultValue)
                                .accessibilityLabel("Default")
                            Tag("default", .yaml)
                        }
                    }
                    GridRow {
                        rowLabel("Lines")
                        HStack {
                            Picker("Lines", selection: $field.isMultiline) {
                                Text("Single").tag(false)
                                Text("Multi-line").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Tag("multiline", .yaml)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            if field.kind == .list {
                Text(supportsSeveralChoices
                    ? "A list box. Several values can be picked with Command or Shift held down."
                    : "A list box. Picking several values needs Espanso 2.4 or later.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let onRemove {
                    Button("Remove Field", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                Spacer()
                if request.originalName == nil {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(request.originalName == nil ? "Insert" : "Done") {
                    var result = field
                    if isMenu, !result.defaultValue.isEmpty, !result.values.contains(result.defaultValue) {
                        result.defaultValue = ""
                    }
                    onSave(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameProblem != nil || (isMenu && field.values.isEmpty))
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 340)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}
