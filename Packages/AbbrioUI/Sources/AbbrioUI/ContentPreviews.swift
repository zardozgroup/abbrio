import SwiftUI
import WebKit

/// Markdown shown roughly as it will look: headings, lists, quotes, code, bold, italic and links.
struct MarkdownPreview: View {
    let text: String

    private struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        var headingLevel: Int?
        var prefix: String?
        var isCode = false
        var isQuote = false
        var indent = 0
    }

    private var blocks: [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var parsed = try? AttributedString(markdown: text, options: options) else {
            return [Block(id: 0, text: AttributedString(text))]
        }
        WebLinks.keepOnlyWebLinks(in: &parsed)
        var blocks: [Block] = []
        var last: PresentationIntent?
        for run in parsed.runs {
            let piece = AttributedString(parsed[run.range])
            let intent = run.presentationIntent
            if let intent, intent == last, !blocks.isEmpty {
                blocks[blocks.count - 1].text += piece
                continue
            }
            last = intent
            var block = Block(id: blocks.count, text: piece)
            var listDepth = 0
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): block.headingLevel = level
                case .codeBlock: block.isCode = true
                case .blockQuote: block.isQuote = true
                case .listItem(let ordinal):
                    if block.prefix == nil { block.prefix = String(ordinal) }
                case .orderedList:
                    listDepth += 1
                    if let ordinal = block.prefix, Int(ordinal) != nil { block.prefix = ordinal + "." }
                case .unorderedList:
                    listDepth += 1
                    block.prefix = "•"
                default: break
                }
            }
            block.indent = max(0, listDepth - 1)
            blocks.append(block)
        }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let prefix = block.prefix {
                        Text(prefix).foregroundStyle(.secondary)
                    }
                    Text(block.text)
                        .font(font(for: block))
                        .foregroundStyle(block.isQuote ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(block.indent) * 14 + (block.isQuote ? 8 : 0))
                .overlay(alignment: .leading) {
                    if block.isQuote {
                        Rectangle().fill(.tertiary).frame(width: 2)
                    }
                }
            }
        }
        .font(.system(size: 13))
    }

    private func font(for block: Block) -> Font {
        if block.isCode { return .system(size: 12, design: .monospaced) }
        switch block.headingLevel {
        case 1?: return .system(size: 20, weight: .bold)
        case 2?: return .system(size: 17, weight: .bold)
        case 3?: return .system(size: 15, weight: .semibold)
        case .some: return .system(size: 13, weight: .semibold)
        case nil: return .system(size: 13)
        }
    }
}

/// HTML shown in a web view that runs no scripts and loads nothing from the network.
struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel("HTML preview")
        context.coordinator.view = view
        context.coordinator.blockNetwork()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(html)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        private var isReady = false
        private var shown: String?
        private var pending: String?
        /// True from the moment the app loads its page until that load is under way. Any other navigation, a
        /// refresh tag or a frame included, is refused.
        private var isExpectingLoad = false

        /// Nothing is drawn until the rule that blocks every load is in place.
        func blockNetwork() {
            let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "abbrio-preview-block-all", encodedContentRuleList: rules
            ) { [weak self] list, _ in
                Task { @MainActor in
                    guard let self, let view = self.view, let list else { return }
                    view.configuration.userContentController.add(list)
                    self.isReady = true
                    if let pending = self.pending { self.show(pending) }
                }
            }
        }

        func show(_ html: String) {
            guard isReady else {
                pending = html
                return
            }
            guard html != shown, let view else { return }
            shown = html
            let page = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
            <style>body { font: 13px -apple-system, sans-serif; margin: 8px; }</style></head><body>\(html)</body></html>
            """
            isExpectingLoad = true
            view.loadHTMLString(page, baseURL: nil)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // Only the page the app wrote is shown. Links, refresh tags and frames in it go nowhere.
            guard isExpectingLoad, navigationAction.navigationType == .other,
                  navigationAction.targetFrame?.isMainFrame == true
            else { return .cancel }
            isExpectingLoad = false
            return .allow
        }
    }
}
