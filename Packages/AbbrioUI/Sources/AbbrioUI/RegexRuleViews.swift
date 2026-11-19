import SwiftUI
import SnippetModel

/// What goes under the Pattern field of a regular expression: what Espanso won't accept, the offer to
/// convert numbered groups, and the caution about matching inside words.
struct RegexPatternNotes: View {
    @Bindable var model: AppModel

    var body: some View {
        if let analysis = model.regexAnalysis {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(analysis.issues, id: \.self) { issue in
                    line(issue.message, "exclamationmark.triangle", .red)
                }
                if let remark = analysis.lengthRemark(limit: model.regexBufferLimit) {
                    line(
                        remark.text, remark.isBlocking ? "exclamationmark.triangle" : "ruler",
                        remark.isBlocking ? .orange : .secondary
                    )
                }
                if model.regexConversion != nil {
                    HStack(spacing: 8) {
                        line(
                            "Espanso refers to groups by name, written (?P<name>…) in the pattern and {{name}} in the expansion.",
                            "arrow.triangle.2.circlepath", .secondary
                        )
                        Button("Convert") { model.applyRegexConversion() }
                            .controlSize(.small)
                            .help("Names the groups and rewrites $1-style references in the expansion")
                    }
                }
                line(
                    "A rule is matched as you type, also in the middle of a word. Start the pattern with characters you would not type otherwise.",
                    "info.circle", .secondary
                )
            }
        }
    }

    private func line(_ text: String, _ systemImage: String, _ color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One button per named group of the pattern. Clicking it puts `{{name}}` into the expansion.
struct RegexGroupBar: View {
    let names: [String]
    let isDisabled: Bool
    let insert: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Groups")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(names, id: \.self) { name in
                        Button {
                            insert("{{\(name)}}")
                        } label: {
                            Label(name, systemImage: "parentheses")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Insert what the group \(name) matched")
                    }
                }
            }
            .disabled(isDisabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Named groups")
    }
}

/// Sample text for a rule, and what the rule makes of it.
struct RegexTester: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try It")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("", text: $model.regexSample, prompt: Text("Type sample text"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .accessibilityLabel("Sample text")
            result
            Text("Tried with the system's regular expression engine, a close approximation of Espanso's.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var result: some View {
        switch model.regexTestOutcome {
        case .idle:
            EmptyView()
        case .unreadable(let reason):
            status("The pattern can't be tried here: \(reason)", "exclamationmark.triangle", .orange)
        case .noMatch:
            status("No match", "xmark.circle", .secondary)
        case .match(let match):
            VStack(alignment: .leading, spacing: 6) {
                if model.regexAnalysis?.issues.isEmpty == false {
                    status("Matches here, but Espanso will not accept the pattern as it is written.", "exclamationmark.triangle", .orange)
                } else {
                    status("Matches", "checkmark.circle.fill", .green)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("Typed") {
                        (Text(match.before).foregroundStyle(.secondary)
                            + Text(match.matched).bold().underline()
                            + Text(match.after).foregroundStyle(.tertiary))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    ForEach(match.groups, id: \.self) { capture in
                        row(capture.name) {
                            Text(capture.value.isEmpty ? "nothing" : capture.value)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(capture.value.isEmpty ? .tertiary : .primary)
                        }
                    }
                    if let output = match.output {
                        row("Output") {
                            Text(output.isEmpty ? " " : output)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private func status(_ text: String, _ systemImage: String, _ color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
