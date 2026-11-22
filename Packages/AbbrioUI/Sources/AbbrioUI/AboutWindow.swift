import AppKit
public import SwiftUI

/// Third-party code inside the app. The list matches `docs/dependencies.md`, and a test keeps the two in step.
public nonisolated struct Acknowledgement: Identifiable, Hashable, Sendable {
    public let name: String
    public let version: String
    public let license: String
    public let url: URL
    /// The package that pulls it in, or the part of Abbrio that uses it.
    public let usedBy: String
    public let purpose: String
    /// The name of its license text in the package's `Licenses` folder.
    let licenseFile: String

    public var id: String { name }

    public static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "Yams", version: "6.2.2", license: "MIT",
            url: URL(string: "https://github.com/jpsim/Yams")!,
            usedBy: "ConfigStore", purpose: "Parsing YAML and reporting where each node starts",
            licenseFile: "Yams"
        ),
        Acknowledgement(
            name: "LibYAML", version: "bundled with Yams", license: "MIT",
            url: URL(string: "https://github.com/yaml/libyaml")!,
            usedBy: "Yams", purpose: "The YAML parser inside Yams",
            licenseFile: "LibYAML"
        ),
        Acknowledgement(
            name: "swift-subprocess", version: "1.0.2", license: "Apache-2.0",
            url: URL(string: "https://github.com/swiftlang/swift-subprocess")!,
            usedBy: "EspansoCLI", purpose: "Running the espanso program and collecting its output",
            licenseFile: "swift-subprocess"
        ),
        Acknowledgement(
            name: "KeyboardShortcuts", version: "1.17.0", license: "MIT",
            url: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!,
            usedBy: "AbbrioUI", purpose: "The global hotkey that opens Quick Search",
            licenseFile: "KeyboardShortcuts"
        ),
        Acknowledgement(
            name: "swift-system", version: "1.8.1", license: "Apache-2.0 with Runtime Library Exception",
            url: URL(string: "https://github.com/apple/swift-system")!,
            usedBy: "swift-subprocess", purpose: "File paths and descriptors for swift-subprocess",
            licenseFile: "swift-system"
        ),
    ]

    /// The full license text, as it ships with the code.
    public var licenseText: String? {
        guard let url = Bundle.module.url(forResource: licenseFile, withExtension: "txt", subdirectory: "Licenses") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The About window: what the app is, who makes it, and the licenses of the code it contains.
public struct AboutView: View {
    /// The window's scene identifier.
    public static let windowID = "about"

    static let websiteURL = URL(string: "https://getabbrio.com")!
    static let sourceURL = URL(string: "https://github.com/zardozgroup/abbrio")!

    @State private var selection: Acknowledgement.ID? = Acknowledgement.all.first?.id

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            acknowledgements
                .padding(20)
        }
        // Wide enough for the 80 columns most license texts are wrapped at.
        .frame(width: 620)
    }

    /// "Version 1.0.0 (2)" from a bundle's Info.plist values.
    nonisolated static func versionText(info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return "Version \(version)"
        }
        return "Version \(version) (\(build))"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Abbrio")
                        .font(.system(size: 22, weight: .semibold))
                    Text("The Mac app for Espanso")
                        .foregroundStyle(.secondary)
                    Text(Self.versionText(info: Bundle.main.infoDictionary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Abbrio is an independent app. It is not made by or affiliated with the Espanso project.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Copyright \u{00A9} 2026 David Orriss Jr and The Zardoz Group LLC. Released under the MIT License.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link("getabbrio.com", destination: Self.websiteURL)
                    Link("Source Code", destination: Self.sourceURL)
                }
                .font(.callout)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Acknowledgements")
                    .font(.headline)
                Text("Abbrio contains the following open-source code. Each keeps its own license.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            List(Acknowledgement.all, selection: $selection) { item in
                AcknowledgementRow(item: item)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 226)
            licenseText
        }
    }

    @ViewBuilder
    private var licenseText: some View {
        let item = Acknowledgement.all.first { $0.id == selection }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.map { "\($0.name) \u{00B7} \($0.license)" } ?? "Select an entry to read its license.")
                    .font(.callout.weight(.medium))
                Spacer()
                if let item {
                    Link("Project Page", destination: item.url)
                        .font(.callout)
                }
            }
            ScrollView {
                Text(item?.licenseText ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

private struct AcknowledgementRow: View {
    let item: Acknowledgement

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .fontWeight(.medium)
                Text(item.version)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(item.purpose). Used by \(item.usedBy).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
    }
}

/// The "About Abbrio" item in the app menu, which opens the About window.
public struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button("About Abbrio") {
            openWindow(id: AboutView.windowID)
            NSApplication.shared.activate()
        }
    }
}

#Preview {
    AboutView()
}

