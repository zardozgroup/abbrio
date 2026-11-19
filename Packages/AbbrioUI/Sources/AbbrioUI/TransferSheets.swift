import AppKit
import ConfigStore
import SnippetModel
import SwiftUI
import UniformTypeIdentifiers

/// The file panels for import and export.
enum TransferPanels {
    static func chooseImport(for model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.message = "Choose a comma- or tab-separated file with abbreviations, expansions and, if you like, descriptions."
        panel.prompt = "Open"
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.beginImport(from: url)
    }

    static func exportList(of id: String, from model: AppModel) {
        guard let set = model.sets.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export as CSV"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = set.name + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportList(of: id, to: url)
    }

    /// Asks where the package folder goes. Nil when the panel was cancelled.
    static func choosePackageParent(named name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Export as Espanso Package"
        panel.message = "A folder named \(name) is created in the folder you choose."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// Shows what a file holds before it becomes a new set.
struct ImportSheet: View {
    @Bindable var model: AppModel
    let pending: PendingImport
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hasHeader: Bool?

    private var source: SnippetImport {
        SnippetImport(text: pending.text, hasHeader: hasHeader)
    }

    var body: some View {
        let source = source
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import \(pending.fileName)")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary(of: source))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("New set")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("The first row holds column names", isOn: Binding(
                get: { source.hasHeader },
                set: { hasHeader = $0 }
            ))

            preview(of: source)

            HStack {
                Text("Columns are read as abbreviation, expansion, description.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.importSet(named: name, from: source) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || source.rows.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear { name = pending.suggestedName }
    }

    private func summary(of source: SnippetImport) -> String {
        let count = source.rows.count
        var text = count == 1 ? "1 abbreviation" : "\(count) abbreviations"
        text += source.delimiter == .tab ? ", separated by tabs." : ", separated by commas."
        if source.skippedCount > 0 {
            let rows = source.skippedCount == 1 ? "1 row is" : "\(source.skippedCount) rows are"
            text += " \(rows) left out for lacking an abbreviation or an expansion."
        }
        return text
    }

    private func preview(of source: SnippetImport) -> some View {
        let shown = Array(source.rows.prefix(200).enumerated())
        return VStack(spacing: 0) {
            row("Abbreviation", "Expansion", "Description", isHeader: true)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.offset) { _, item in
                        row(item.abbreviation, item.expansion, item.description, isHeader: false)
                        Divider().opacity(0.5)
                    }
                    if source.rows.count > shown.count {
                        Text("and \(source.rows.count - shown.count) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    if source.rows.isEmpty {
                        Text("Nothing in this file can be imported.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }
                }
            }
            .frame(height: 220)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(_ abbreviation: String, _ expansion: String, _ description: String, isHeader: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(abbreviation)
                .font(isHeader ? .system(size: 11, weight: .semibold) : .system(size: 12, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text(expansion.replacingOccurrences(of: "\n", with: " \u{23CE} "))
                .font(.system(size: isHeader ? 11 : 12, weight: isHeader ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(description)
                .font(.system(size: isHeader ? 11 : 12, weight: isHeader ? .semibold : .regular))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
        }
        .lineLimit(1)
        .foregroundStyle(isHeader ? .secondary : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// Asks for what a package's manifest says, then writes the package folder.
struct PackageExportSheet: View {
    @Bindable var model: AppModel
    let setID: String
    @Environment(\.dismiss) private var dismiss
    @State private var manifest = PackageManifest()
    @State private var hasLoaded = false

    private var set: SnippetSet? {
        model.sets.first { $0.id == setID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Export \u{201C}\(set?.name ?? "")\u{201D} as an Espanso Package")
                    .font(.system(size: 15, weight: .semibold))
                Text("Writes a folder with package.yml, _manifest.yml and README.md. Put it in a git repository and others can install it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
                field("Name", text: $manifest.name, tag: "name", monospaced: true)
                field("Title", text: $manifest.title, tag: "title")
                field("Author", text: $manifest.author, tag: "author")
                field("Version", text: $manifest.version, tag: "version", monospaced: true)
                field("Description", text: $manifest.description, tag: "description")
            }

            if model.refersToConfigFolder(setID) {
                Label(
                    "This set refers to files in your config folder ($CONFIG), such as pictures or scripts. They are not part of the package.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let problem = manifest.problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("The README lists the set\u{2019}s \(set?.snippets.count ?? 0) items.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export\u{2026}", action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(manifest.problem != nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            manifest = model.suggestedManifest(for: setID)
        }
    }

    private func field(_ title: String, text: Binding<String>, tag: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12))
                .gridColumnAlignment(.trailing)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            Tag(tag, .yaml)
        }
    }

    private func export() {
        guard let parent = TransferPanels.choosePackageParent(named: manifest.name),
              let folder = model.exportPackage(of: setID, manifest: manifest, to: parent)
        else { return }
        dismiss()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
