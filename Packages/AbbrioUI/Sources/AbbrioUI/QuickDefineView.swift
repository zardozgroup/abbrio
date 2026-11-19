public import SwiftUI
import SnippetModel

/// The compact window behind "New Item from Clipboard" and "New Item from Selection".
public struct QuickDefineView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let request = model.quickDefine {
                QuickDefineForm(model: model, request: request) {
                    model.quickDefine = nil
                    dismissWindow(id: "quick-define")
                }
                // A new request starts with fresh fields.
                .id(request.id)
            } else {
                Text("Choose New Item from Clipboard or New Item from Selection in the menu bar menu.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
        .frame(width: 420)
        .navigationTitle(model.quickDefine?.title ?? "New Item")
    }
}

struct QuickDefineForm: View {
    let model: AppModel
    let request: QuickDefineRequest
    let close: () -> Void

    @State private var abbreviation = ""
    @State private var description = ""
    @State private var text: String
    @State private var setID: String?
    @State private var problem: String?
    @FocusState private var abbreviationIsFocused: Bool

    init(model: AppModel, request: QuickDefineRequest, close: @escaping () -> Void) {
        self.model = model
        self.request = request
        self.close = close
        _text = State(initialValue: request.text)
        _setID = State(initialValue: model.quickDefineSetID)
    }

    private var set: SnippetSet? {
        model.quickDefineSets.first { $0.id == setID }
    }

    private var canSave: Bool {
        setID != nil && !abbreviation.trimmingCharacters(in: .whitespaces).isEmpty && !text.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                field("Abbreviation", tag: "trigger") {
                    TextField("", text: $abbreviation)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($abbreviationIsFocused)
                        .accessibilityLabel("Abbreviation")
                }
                field("Description", tag: "label") {
                    TextField("", text: $description)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Description")
                }
            }

            field(request.source == .clipboard ? "Expansion · from the clipboard" : "Expansion · from the selection", tag: "replace") {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 84)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    .accessibilityLabel("Expansion")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    caption("Set")
                    Spacer()
                    Text("Remembers the last set used")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Picker("Set", selection: $setID) {
                    ForEach(model.quickDefineSets) { set in
                        Text(set.name).tag(Optional(set.id))
                    }
                }
                .labelsHidden()
                if let set {
                    defaults(of: set)
                }
            }

            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let path = model.quickDefinePath(forSet: setID) {
                    (Text("Saves to ") + Text(path).font(.system(size: 11, design: .monospaced)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .onAppear { abbreviationIsFocused = true }
    }

    private func save() {
        guard let setID else { return }
        problem = model.saveQuickDefine(abbreviation: abbreviation, description: description, text: text, setID: setID)
        if problem == nil { close() }
    }

    /// The set's default options, which the new item gets.
    private func defaults(of set: SnippetSet) -> some View {
        let caseName: String
        switch set.info.defaultCase {
        case .mustMatch: caseName = "Case must match"
        case .insensitive: caseName = "Case does not matter"
        case .affectsExpansion: caseName = "Case affects expansion"
        }
        let typed = model.quickDefineTriggers(for: abbreviation.trimmingCharacters(in: .whitespaces), inSet: set.id)
        let showsTyped = !abbreviation.isEmpty && (!set.info.prefix.isEmpty || !set.info.suffix.isEmpty)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                chip(caseName)
                chip(set.info.defaultExpand == .wordBreak ? "At word break" : "On match")
                Text("from \(set.name)’s default options")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsTyped, let first = typed.first {
                // The set adds its prefix and suffix to what is typed here.
                (Text("Typed as ") + Text(first).font(.system(size: 11, design: .monospaced)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func field<Content: View>(_ title: String, tag: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                caption(title)
                Spacer(minLength: 4)
                Tag(tag, .yaml)
            }
            content()
        }
    }
}
