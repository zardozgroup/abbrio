import AppKit
import ConfigStore
import EspansoCLI
import SnippetModel
import SwiftUI

/// One Hub package in full: its README, what it would add, and the buttons to install or remove it.
struct PackageDetailSheet: View {
    let model: AppModel
    let package: HubPackage
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingUninstall = false

    private var standing: PackageStanding { model.standing(ofPackageNamed: package.name) }
    private var isBusy: Bool { model.packageCenter.activity[package.name] != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                readme
                Divider()
                preview
                    .frame(width: 250)
                    .background(Color.primary.opacity(0.025))
            }
            .frame(height: 380)
            Divider()
            footer
        }
        .frame(width: 680)
        .task(id: package.id) { await model.loadPreview(of: package) }
        .confirmationDialog("Uninstall \(package.name)?", isPresented: $isConfirmingUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstallPackage(package.name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Espanso removes the package\u{2019}s folder. Items you copied to your own sets stay.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                PackageIcon(size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.displayTitle).font(.system(size: 18, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(package.name).font(.system(size: 12, design: .monospaced))
                        if !package.author.isEmpty { Text("\u{00B7}  by \(package.author)") }
                        Text("\u{00B7}  version \(package.version)")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let page = package.hubPage {
                    Link(destination: page) {
                        Label("View on Hub", systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.system(size: 12))
                }
            }
            if !package.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(package.tags.prefix(8), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
        }
        .padding(20)
    }

    private var readme: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("README")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                switch model.packageCenter.previews[package.id] {
                case .loaded(let contents):
                    if let text = contents.readme, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownView(text: text)
                    } else {
                        Text(package.description.isEmpty ? "This package has no README." : package.description)
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    Text(package.description).fixedSize(horizontal: false, vertical: true)
                    Text("The README is in the package\u{2019}s archive, which could not be fetched.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    Text(package.description).fixedSize(horizontal: false, vertical: true)
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snippets preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Read from the downloaded archive").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            switch model.packageCenter.previews[package.id] {
            case .loaded(let contents):
                loadedPreview(contents)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    model.forgetPreview(of: package)
                    Task { await model.loadPreview(of: package) }
                }
                .controlSize(.small)
                Spacer()
            default:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading\u{2026}").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func loadedPreview(_ contents: PackageContents) -> some View {
        let triggers = contents.snippets.flatMap(\.triggers)
        let conflicts = model.conflicts(ofTriggers: triggers, inPackageNamed: package.name)
        VStack(spacing: 0) {
            HStack {
                Text("Trigger").frame(width: 92, alignment: .leading)
                Text("Expansion")
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(contents.snippets) { snippet in
                        HStack(alignment: .firstTextBaseline) {
                            Text(snippet.regex ?? snippet.triggers.joined(separator: ", "))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 92, alignment: .leading)
                            Text(PackageText.summary(of: snippet))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        Divider().opacity(0.5)
                    }
                    if contents.snippets.isEmpty {
                        Text(contents.hasUnreadableFiles ? "The package\u{2019}s items could not be read." : "The package has no items.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))

        if !conflicts.isEmpty {
            Label {
                Text(conflictText(conflicts))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.system(size: 11))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.5)))
        }
    }

    private func conflictText(_ conflicts: [PackageConflict]) -> String {
        guard let first = conflicts.first else { return "" }
        if conflicts.count == 1 {
            return "\(first.trigger) already exists in \(first.setName). Espanso will ask which one to use."
        }
        return "\(first.trigger) and \(conflicts.count - 1) more already exist in your sets. Espanso will ask which one to use."
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            PackageActivity(model: model, name: package.name)
            Spacer()
            let versions = model.packageCenter.index.versions(of: package.name)
            if versions.count > 1 {
                Menu("Install Specific Version\u{2026}") {
                    ForEach(versions) { version in
                        Button(version.version) { Task { await model.installPackage(package.name, version: version.version) } }
                    }
                }
                .fixedSize()
                .disabled(isBusy)
            }
            switch standing {
            case .notInstalled:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { Task { await model.installPackage(package.name) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || model.configFolder == nil)
            case .installed, .updateAvailable:
                Button("Uninstall\u{2026}", role: .destructive) { isConfirmingUninstall = true }
                    .disabled(isBusy)
                if case .updateAvailable = standing {
                    Button("Update") { Task { await model.updatePackage(package.name) } }
                        .disabled(isBusy)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Asks for a package name and a repository, and installs from there.
struct GitInstallSheet: View {
    let model: AppModel
    /// Called with the package's name once it is installed.
    let installed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
    private var arguments: [String]? {
        EspansoClient.installArguments(name: trimmedName, gitURL: trimmedURL)
    }
    private var isBusy: Bool { model.packageCenter.activity[trimmedName] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install from Git URL").font(.system(size: 15, weight: .semibold))
                Text("Installs a package in Espanso\u{2019}s package format from a GitHub or GitLab repository, or from another git host through git clone.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    Text("Package name").gridColumnAlignment(.trailing)
                    TextField("my-package", text: $name)
                        .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text("Repository URL")
                    TextField("https://github.com/someone/repository", text: $url)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .disabled(isBusy)

            Label {
                Text("External packages aren\u{2019}t reviewed by the Espanso team, unlike Hub packages. Install only from sources you trust.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.5)))

            VStack(alignment: .leading, spacing: 5) {
                Text("Command the app runs").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(command)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tag.yamlColor, in: RoundedRectangle(cornerRadius: 5))
            }

            PackageActivity(model: model, name: trimmedName)

            HStack {
                if !trimmedName.isEmpty, !trimmedURL.isEmpty, arguments == nil {
                    Text("The name may hold letters, digits, dots, hyphens and underscores; the address must be one word.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    let name = trimmedName, url = trimmedURL
                    Task {
                        if await model.installPackage(name, fromGit: url) {
                            installed(name)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(arguments == nil || isBusy)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private var command: String {
        "espanso " + (arguments ?? ["install", trimmedName.isEmpty ? "<name>" : trimmedName, "--git",
                                    trimmedURL.isEmpty ? "<url>" : trimmedURL, "--external"]).joined(separator: " ")
    }
}
