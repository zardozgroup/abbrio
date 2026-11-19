public import SwiftUI
import SnippetModel

/// The abbreviation list in the middle of the window.
struct SnippetListView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.configFolder == nil {
            ContentUnavailableView(
                "No Espanso Folder Found",
                systemImage: "folder.badge.questionmark",
                description: Text("Install Espanso and start it once, then open Abbrio again.")
            )
        } else if model.sets.isEmpty {
            ContentUnavailableView(
                "No Abbreviation Sets",
                systemImage: "tray",
                description: Text("The match folder has no files yet.")
            )
        } else if !model.isSearching, let set = model.selectedSet, set.isBroken {
            brokenFile(set)
        } else if model.rows.isEmpty {
            if model.isSearching {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ContentUnavailableView {
                    Label("No Abbreviations", systemImage: "text.cursor")
                } description: {
                    Text("This set is empty.")
                } actions: {
                    if model.canAddItem {
                        Button(model.newItemTitle) { model.newItem() }
                    }
                }
            }
        } else {
            table
        }
    }

    private var table: some View {
        SnippetTable(model: model, rows: model.rows, selection: model.selectedSnippetID, sortOrder: model.sortOrder)
            .confirmationDialog(
                "Delete \u{201C}\(model.selectedSnippet?.abbreviation ?? "")\u{201D}?",
                isPresented: $model.isConfirmingItemDeletion
            ) {
                Button("Delete", role: .destructive) { model.deleteSelectedItem() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The item is removed from \(model.selectedSnippet?.id.file ?? "its file"). You can undo this.")
            }
    }

    private func brokenFile(_ set: SnippetSet) -> some View {
        let problem = set.problems.first { $0.severity == .unreadable }
        return ContentUnavailableView {
            Label("This File Can't Be Read", systemImage: "exclamationmark.triangle")
        } description: {
            if let problem {
                Text(problem.line.map { "\(problem.file), line \($0)" } ?? problem.file)
                Text(problem.message)
            }
            Text("Fix the YAML in the pane on the right.")
        } actions: {
            if let url = set.files.first?.url {
                Button("Open in External Editor") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.listSummary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if !model.rows.isEmpty {
                Text("Sorted by \(model.sortColumnName)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

/// One mark in the Options column.
struct OptionGlyphView: View {
    let glyph: OptionGlyph

    var body: some View {
        Group {
            switch glyph {
            case .duplicateTrigger:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            case .form:
                boxed(Image(systemName: "list.bullet.rectangle").font(.system(size: 9)))
            case .picture:
                boxed(Image(systemName: "photo").font(.system(size: 9)))
            default:
                boxed(Text(text).font(.system(size: 9, weight: .medium, design: .monospaced)))
            }
        }
        .help(glyph.help)
        .accessibilityLabel(glyph.help)
    }

    private var text: String {
        switch glyph {
        case .caseAffectsExpansion: return "Aa"
        case .wordBreak: return "␣"
        case .dynamicContent: return "{ }"
        case .script: return ">_"
        case .regex: return ".*"
        case .markdown: return "M↓"
        case .html: return "</>"
        case .form, .picture, .duplicateTrigger: return ""
        }
    }

    private func boxed(_ content: some View) -> some View {
        content
            .padding(.horizontal, 3)
            .frame(minWidth: 18, minHeight: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(.secondary.opacity(0.7), lineWidth: 1)
            )
            .foregroundStyle(.secondary)
    }
}
