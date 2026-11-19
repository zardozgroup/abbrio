import SwiftUI

/// A small label that says where a setting is kept: in Espanso's YAML, or in the app's own notes.
struct Tag: View {
    enum Kind {
        /// Changes one of Espanso's files.
        case yaml
        /// Kept by the app only.
        case sidecar
    }

    let text: String
    let kind: Kind

    init(_ text: String, _ kind: Kind) {
        self.text = text
        self.kind = kind
    }

    static let yamlColor = Color(red: 0.76, green: 0.09, blue: 0.36)

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: kind == .yaml ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(kind == .yaml ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                kind == .yaml ? AnyShapeStyle(Self.yamlColor) : AnyShapeStyle(Color.primary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .fixedSize()
            .accessibilityLabel(kind == .yaml ? "Written to YAML: \(text)" : "Kept by the app: \(text)")
    }
}
