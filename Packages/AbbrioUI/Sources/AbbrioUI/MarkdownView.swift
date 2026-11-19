import SwiftUI

/// Shows Markdown as headings, paragraphs, lists, quotes and code, using the system's parser.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownBlock.blocks(in: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .rule:
            Divider()
        case .code:
            Text(block.text)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .heading(let level):
            Text(block.text)
                .font(.system(size: level <= 1 ? 17 : level == 2 ? 15 : 13, weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let marker = block.marker {
                    Text(marker)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(block.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
            .foregroundStyle(block.isQuote ? .secondary : .primary)
            .padding(.leading, CGFloat(block.depth) * 16 + (block.marker == nil && block.depth > 0 ? 14 : 0))
            .overlay(alignment: .leading) {
                if block.isQuote {
                    Rectangle().fill(.tertiary).frame(width: 3)
                }
            }
            .padding(.leading, block.isQuote ? 10 : 0)
        }
    }
}

/// One block of a Markdown text.
nonisolated struct MarkdownBlock {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case code
        case rule
    }

    var kind: Kind
    var text: AttributedString
    /// The bullet or number in front of a list item's first paragraph.
    var marker: String?
    /// How many lists the block is nested in, less one.
    var depth = 0
    var isQuote = false

    static func blocks(in source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var parsed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(source))]
        }
        WebLinks.keepOnlyWebLinks(in: &parsed)

        var blocks: [MarkdownBlock] = []
        var lastKey: Int?
        var lastCell: Int?
        var markedItems: Set<Int> = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            var block = MarkdownBlock(kind: .paragraph, text: AttributedString(parsed[run.range]))
            // Cells of one table row are joined on a line; everything else is keyed by its innermost part.
            var key = components.first?.identity ?? -1
            var lists = 0
            var item: (identity: Int, ordinal: Int)?
            var isOrdered = false
            var cell: Int?
            for (position, component) in components.enumerated() {
                switch component.kind {
                case .header(let level): block.kind = .heading(level)
                case .codeBlock: block.kind = .code
                case .thematicBreak: block.kind = .rule
                case .blockQuote: block.isQuote = true
                case .listItem(let ordinal):
                    if item == nil {
                        item = (component.identity, ordinal)
                        // The list a first item belongs to comes right after it.
                        if position + 1 < components.count, case .orderedList = components[position + 1].kind {
                            isOrdered = true
                        }
                    }
                case .orderedList, .unorderedList: lists += 1
                case .tableCell: cell = component.identity
                case .tableRow, .tableHeaderRow: if cell != nil { key = component.identity }
                default: break
                }
            }
            block.depth = max(0, lists - 1)
            if let item, markedItems.insert(item.identity).inserted {
                block.marker = isOrdered ? "\(item.ordinal)." : "\u{2022}"
            }
            if block.kind == .code {
                // A code block ends with the line break that closed it.
                var text = String(block.text.characters)
                while text.hasSuffix("\n") { text.removeLast() }
                block.text = AttributedString(text)
            }
            if key == lastKey, var last = blocks.popLast() {
                if let cell, cell != lastCell { last.text += AttributedString("   \u{00B7}   ") }
                last.text += block.text
                blocks.append(last)
            } else {
                blocks.append(block)
            }
            lastKey = key
            lastCell = cell
        }
        return blocks
    }
}

/// Keeps links in Markdown only when they lead to a web page. Any other link, such as `file:`, `javascript:` or
/// an app's own scheme, stays as plain text, so a click can't open a file or another app.
nonisolated enum WebLinks {
    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func keepOnlyWebLinks(in text: inout AttributedString) {
        for run in text.runs {
            if let link = run.link, !isWebLink(link) {
                text[run.range].link = nil
            }
        }
    }
}
