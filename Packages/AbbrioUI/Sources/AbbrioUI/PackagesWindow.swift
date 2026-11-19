import AppKit
import ConfigStore
import SnippetModel
public import SwiftUI

/// The Packages window: what is installed, and the Hub's catalog to install from.
public struct PackagesWindow: View {
    let model: AppModel

    @State private var selectedPackage: String?
    @State private var search = ""
    @State private var tag: String?
    @State private var featuredOnly = false
    @State private var detail: HubPackage?

    public init(model: AppModel) {
        self.model = model
    }

    private var center: PackageCenter { model.packageCenter }

    public var body: some View {
        @Bindable var model = model
        ZStack {
            if model.packagesTab == .installed {
                InstalledPackagesView(model: model, selection: $selectedPackage)
            } else {
                hub
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $model.packagesTab) {
                    Text("Installed").tag(PackagesTab.installed)
                    Text("Browse Hub").tag(PackagesTab.hub)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.packagesTab == .hub {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search packages", text: $search)
                            .textFieldStyle(.plain)
                            .frame(width: 190)
                    }
                    .modifier(ToolbarSearchFieldChrome())
                }
                if #available(macOS 26, *) {
                    // Keeps the field in a capsule of its own instead of sharing one with the buttons.
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.packagesTab == .hub {
                    Button {
                        Task { await model.loadCatalog(force: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Fetch the catalog again")
                    .disabled(center.isRefreshing)
                }
                Button("Install from Git URL\u{2026}") { model.isAskingForGitInstall = true }
                    .disabled(model.configFolder == nil)
            }
        }
        .task {
            if !model.hasLoaded { await model.load() }
            await model.loadCatalog()
        }
        .onChange(of: model.packagesTab) { _, tab in
            if tab == .hub { Task { await model.loadCatalog() } }
        }
        .sheet(item: $detail) { package in
            PackageDetailSheet(model: model, package: package)
        }
        .sheet(isPresented: $model.isAskingForGitInstall) {
            GitInstallSheet(model: model) { name in
                selectedPackage = "packages/" + name
                model.packagesTab = .installed
            }
        }
    }

    // MARK: Browse Hub

    private var results: [HubPackage] {
        center.index.results(search: search, tag: tag, featuredOnly: featuredOnly, featured: center.featured)
    }

    private var hub: some View {
        VStack(spacing: 0) {
            if center.index.entries.isEmpty {
                emptyCatalog
            } else {
                tagBar
                Divider()
                let results = results
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { package in
                            HubPackageRow(model: model, package: package) { detail = package }
                        }
                        if results.isEmpty {
                            Text("No package matches.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 60)
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            catalogFooter
        }
    }

    private var tagBar: some View {
        let counts = center.index.tagCounts
        let shown = Array(counts.prefix(4))
        return HStack(spacing: 8) {
            Text("Tags")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TagChip(title: "All", count: nil, isOn: tag == nil) { tag = nil }
            ForEach(shown, id: \.tag) { entry in
                TagChip(title: entry.tag, count: entry.count, isOn: tag == entry.tag) { tag = entry.tag }
            }
            if let tag, !shown.contains(where: { $0.tag == tag }) {
                TagChip(title: tag, count: counts.first { $0.tag == tag }?.count, isOn: true) {}
            }
            if counts.count > shown.count {
                Menu("More\u{2026}") {
                    ForEach(counts.dropFirst(shown.count), id: \.tag) { entry in
                        Button("\(entry.tag)  \(entry.count)") { tag = entry.tag }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            Toggle("Featured only", isOn: $featuredOnly)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var emptyCatalog: some View {
        VStack(spacing: 12) {
            Spacer()
            if center.isRefreshing {
                ProgressView()
                Text("Fetching the catalog\u{2026}").foregroundStyle(.secondary)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("The Hub\u{2019}s catalog isn\u{2019}t available")
                    .font(.system(size: 15, weight: .semibold))
                Text(center.catalogError ?? "It has not been fetched yet.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack {
                    Button("Try Again") { Task { await model.loadCatalog(force: true) } }
                    Button("Open hub.espanso.org") { NSWorkspace.shared.open(HubIndex.website) }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var catalogFooter: some View {
        HStack(spacing: 6) {
            if center.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Fetching the catalog\u{2026}")
            } else if let date = center.catalogDate {
                Text("Catalog: copy from \(date.formatted(date: .abbreviated, time: .shortened)) \u{00B7} refreshes after 24 hours or with the Refresh button")
            } else {
                Text("Catalog: none yet")
            }
            Spacer()
            if let error = center.catalogError, !center.index.entries.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: Pieces

/// From macOS 26 the toolbar draws a capsule around each item, so the field adds no border of its own.
/// Earlier versions draw nothing behind toolbar items, so the field draws its own rounded box.
private struct ToolbarSearchFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.padding(.horizontal, 6)
        } else {
            content
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

private struct TagChip: View {
    let title: String
    let count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)").foregroundStyle(isOn ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: isOn ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The box icon the package rows and sheets carry.
struct PackageIcon: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: size * 0.45))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

/// A small coloured label: Featured, Installed, Update available.
struct PackageBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
    }
}

/// What a package command is doing, or what Espanso printed when it failed.
struct PackageActivity: View {
    let model: AppModel
    let name: String

    var body: some View {
        if let activity = model.packageCenter.activity[name] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(activity).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        } else if let failure = model.packageCenter.failures[name] {
            VStack(alignment: .leading, spacing: 3) {
                Label("Espanso reported:", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(failure)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
        }
    }
}

private struct HubPackageRow: View {
    let model: AppModel
    let package: HubPackage
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        let standing = model.standing(ofPackageNamed: package.name)
        let isBusy = model.packageCenter.activity[package.name] != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                PackageIcon()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(package.displayTitle).font(.system(size: 14, weight: .semibold))
                        Text(package.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        if !package.author.isEmpty {
                            Text("by \(package.author)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    if !package.description.isEmpty {
                        Text(package.description).font(.system(size: 13)).lineLimit(1)
                    }
                    if !package.tags.isEmpty {
                        Text(package.tags.joined(separator: " \u{00B7} "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                switch standing {
                case .updateAvailable: PackageBadge(text: "Update available", color: .orange)
                case .installed: PackageBadge(text: "Installed", color: .green)
                case .notInstalled:
                    if model.packageCenter.featured.contains(package.name) {
                        PackageBadge(text: "Featured", color: Color(red: 0.72, green: 0.5, blue: 0.05))
                    }
                }
                Group {
                    switch standing {
                    case .notInstalled:
                        Button("Install") { Task { await model.installPackage(package.name) } }
                    case .installed:
                        Button("Installed") {}.disabled(true)
                    case .updateAvailable:
                        Button("Update") { Task { await model.updatePackage(package.name) } }
                    }
                }
                .frame(width: 84)
                .disabled(isBusy || model.configFolder == nil)
            }
            PackageActivity(model: model, name: package.name)
                .padding(.leading, 54)
        }
        .padding(12)
        .background(
            isHovered ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: open)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show Details", open)
    }
}

// MARK: Installed

private struct InstalledPackagesView: View {
    let model: AppModel
    @Binding var selection: String?
    @State private var selectedItems: Set<Snippet.ID> = []
    @State private var uninstallTarget: String?
    @State private var isAskingForSetName = false
    @State private var newSetName = ""

    private var packages: [SnippetSet] { model.installedPackages }
    private var selected: SnippetSet? { packages.first { $0.id == selection } ?? packages.first }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 250)
            Divider()
            if let package = selected {
                detail(package)
            } else {
                empty
            }
        }
        .confirmationDialog(
            "Uninstall \(uninstallTarget ?? "")?", isPresented: Binding(
                get: { uninstallTarget != nil }, set: { if !$0 { uninstallTarget = nil } }
            ), presenting: uninstallTarget
        ) { name in
            Button("Uninstall", role: .destructive) { Task { await model.uninstallPackage(name) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Espanso removes the package\u{2019}s folder. Items you copied to your own sets stay.")
        }
        .alert("New Set", isPresented: $isAskingForSetName) {
            TextField("Name", text: $newSetName)
            Button("Copy") {
                if let package = selected { model.copyToMySets(itemsToCopy(from: package), toNewSetNamed: newSetName) }
                newSetName = ""
            }
            .disabled(newSetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newSetName = "" }
        } message: {
            Text("The items are copied into a new set you can edit.")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Installed \u{00B7} \(packages.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            List(selection: Binding(get: { selected?.id }, set: { selection = $0; selectedItems = [] })) {
                ForEach(packages) { package in
                    let name = AppModel.packageName(ofSet: package.id)
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.system(size: 13, weight: .medium))
                            Text("match/packages/\(name)").font(.system(size: 10.5)).opacity(0.75)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 4)
                        if model.hasUpdate(package) {
                            PackageBadge(text: "Update", color: .orange)
                        } else {
                            Image(systemName: "lock").font(.system(size: 10)).opacity(0.7)
                                .accessibilityLabel("Read-only")
                        }
                    }
                    .tag(package.id)
                }
            }
            .listStyle(.sidebar)
            Text("An Update badge appears here when the Hub catalog lists a newer version. Browse Hub lists every package you can install.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .padding(10)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            PackageIcon(size: 52)
            Text("No packages installed").font(.system(size: 15, weight: .semibold))
            Text("Packages are ready-made sets from the Espanso Hub or a git repository.")
                .foregroundStyle(.secondary)
            Button("Browse Hub") { model.packagesTab = .hub }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// True when any of the items runs a shell command or a script, directly or through a form's fields.
    private func runsCommands(_ ids: [Snippet.ID], in package: SnippetSet) -> Bool {
        let chosen = Set(ids)
        return package.snippets.contains { snippet in
            chosen.contains(snippet.id) && snippet.variables.contains { ["shell", "script"].contains($0.type) }
        }
    }

    private func itemsToCopy(from package: SnippetSet) -> [Snippet.ID] {
        package.snippets.map(\.id).filter { selectedItems.isEmpty || selectedItems.contains($0) }
    }

    private func detail(_ package: SnippetSet) -> some View {
        let name = AppModel.packageName(ofSet: package.id)
        let info = package.packageInfo ?? PackageInfo(name: name)
        let isBusy = model.packageCenter.activity[name] != nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 20, weight: .semibold))
                    Text("Read-only. Updates overwrite it, so edits go in a copy.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update") { Task { await model.updatePackage(name) } }
                    .disabled(isBusy || !canUpdate(package))
                    .help(canUpdate(package) ? "Runs espanso package update \(name)" : "The Hub catalog lists no newer version")
                Button("Uninstall\u{2026}", role: .destructive) { uninstallTarget = name }
                    .disabled(isBusy)
            }
            PackageActivity(model: model, name: name)

            HStack {
                Text("Manifest").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Tag("_manifest.yml", .yaml)
            }
            manifestTable(info)
            if case .git(let url) = info.source, !url.isEmpty {
                Text("Installed from \(url)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Items (read-only)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu("Copy to My Sets\u{2026}") {
                    if runsCommands(itemsToCopy(from: package), in: package) {
                        Text("Some of these items run commands or scripts.")
                        Divider()
                    }
                    ForEach(model.copyTargets) { target in
                        Button(target.name) { model.copyToMySets(itemsToCopy(from: package), toSet: target.id) }
                    }
                    if !model.copyTargets.isEmpty { Divider() }
                    Button("New Set\u{2026}") { isAskingForSetName = true }
                }
                .fixedSize()
                .disabled(package.snippets.isEmpty)
            }
            items(package)
            Text(selectedItems.isEmpty
                ? "Copy to My Sets duplicates every item into an editable set; select items to copy only those. The package copy stays untouched."
                : "Copy to My Sets duplicates the selected items into an editable set. The package copy stays untouched.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if runsCommands(itemsToCopy(from: package), in: package) {
                Label(
                    "Some of these items run commands or scripts with your permissions. Once copied, they run whenever you type their abbreviation, in every app where the set is on.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack(spacing: 8) {
                Tag("extra_excludes", .yaml)
                Text("A package is turned off per app in the Apps window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Apps") { model.openWindow?("apps") }
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Hub packages update when the catalog has a newer version; for a git package only Espanso can tell.
    private func canUpdate(_ package: SnippetSet) -> Bool {
        if case .git = package.packageInfo?.source { return true }
        return model.hasUpdate(package)
    }

    private func manifestTable(_ info: PackageInfo) -> some View {
        let rows: [(String, String)] = [
            ("name", info.name), ("title", info.title), ("version", info.version), ("author", info.author),
            ("tags", info.tags.joined(separator: ", ")), ("description", info.description),
        ]
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.0)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(row.1.isEmpty ? "\u{2014}" : row.1)
                        .font(.system(size: 13))
                        .foregroundStyle(row.1.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if index < rows.count - 1 { Divider() }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func items(_ package: SnippetSet) -> some View {
        Table(package.snippets, selection: $selectedItems) {
            TableColumn("Abbreviation") { snippet in
                Text(snippet.regex ?? snippet.triggers.joined(separator: ", "))
                    .font(.system(size: 12, design: .monospaced))
            }
            .width(min: 100, ideal: 170)
            TableColumn("Expansion") { snippet in
                Text(PackageText.summary(of: snippet))
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 120)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// How an item's expansion reads on one line.
nonisolated enum PackageText {
    static func summary(of snippet: Snippet) -> String {
        switch snippet.expansion {
        case .image(let path): return "Picture: " + (path as NSString).lastPathComponent
        case .missing: return "\u{2014}"
        default: return snippet.expansion.body.replacingOccurrences(of: "\n", with: " \u{23CE} ")
        }
    }
}
