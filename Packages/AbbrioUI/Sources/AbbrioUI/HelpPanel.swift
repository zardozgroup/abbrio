import AppKit
public import SwiftUI

/// The places the Help button and the Help menu lead to.
public nonisolated enum HelpDestination: String, CaseIterable, Identifiable, Sendable {
    case helpCenter
    case supportRequest
    case bugReport

    public var id: String { rawValue }

    public var url: URL {
        switch self {
        case .helpCenter:
            return URL(string: "https://getabbrio.com/help/")!
        case .supportRequest:
            return URL(string: "https://github.com/zardozgroup/abbrio/issues/new?template=general-support-request.md")!
        case .bugReport:
            return URL(string: "https://github.com/zardozgroup/abbrio/issues/new?template=bug_report.md")!
        }
    }

    public var title: String {
        switch self {
        case .helpCenter: return "Help Center"
        case .supportRequest: return "Ask for Support"
        case .bugReport: return "Report a Bug"
        }
    }

    /// The title as a menu item, which says that it leaves the app.
    public var menuTitle: String {
        switch self {
        case .helpCenter: return "Abbrio Help Center"
        case .supportRequest: return "Ask for Support\u{2026}"
        case .bugReport: return "Report a Bug\u{2026}"
        }
    }

    var detail: String {
        switch self {
        case .helpCenter: return "Guides and answers to common questions."
        case .supportRequest: return "Something isn\u{2019}t clear or doesn\u{2019}t work for you? Open a request."
        case .bugReport: return "Send a technical report of a fault, with the steps that lead to it."
        }
    }

    var systemImage: String {
        switch self {
        case .helpCenter: return "book"
        case .supportRequest: return "bubble.left.and.text.bubble.right"
        case .bugReport: return "ladybug"
        }
    }

    /// Where the page opens, for the line under the choice.
    var host: String { url.host ?? "" }

    @MainActor
    public func open() {
        NSWorkspace.shared.open(url)
    }
}

/// The panel behind the toolbar's Help button: three ways to get help, each opening in the browser.
struct HelpPanel: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How can we help?")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 4)
            ForEach(HelpDestination.allCases) { destination in
                HelpChoice(destination: destination) {
                    destination.open()
                    dismiss()
                }
            }
            Text("Each choice opens in your browser. The support and bug forms need a GitHub account.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct HelpChoice: View {
    let destination: HelpDestination
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(destination.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(destination.host)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityHint("Opens in your browser")
    }
}
