import AppKit
import SwiftUI
import SnippetModel

/// How a variable, field or the cursor marker looks in the expansion editor.
nonisolated struct ChipStyle: Hashable {
    enum Tone: Hashable {
        case cursor, field, variable, unknown
    }

    var title: String
    var symbol: String
    var tone: Tone
    /// What VoiceOver and the tooltip say.
    var help: String
}

/// Lets the Insert menu put text into the editor at the insertion point.
final class ExpansionEditorProxy {
    fileprivate weak var textView: NSTextView?

    /// Inserts text where the insertion point is, replacing the selection. Returns false when the editor
    /// is not on screen.
    @discardableResult
    func insert(_ text: String) -> Bool {
        guard let textView, textView.isEditable else { return false }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }
}

/// The expansion's text, with the cursor marker and every `{{variable}}` shown as a chip.
///
/// The chips are a view of the text only: what is saved is the text with each chip written out again as
/// it was (`$|$`, `{{name}}`, `[[field]]`).
struct ExpansionEditor: NSViewRepresentable {
    var text: String
    var isShortForm: Bool
    var isMonospaced: Bool
    var isEditable: Bool
    /// Changes whenever a chip's title may have, so the chips are drawn again.
    var signature: Int
    var style: (ExpansionPiece) -> ChipStyle
    var proxy: ExpansionEditorProxy
    var onChange: (String) -> Void
    /// A chip was clicked. The rectangle is the chip's, in this view's coordinates from the top left.
    var onChipClick: (ExpansionPiece, CGRect) -> Void
    var onEndEditing: () -> Void
    /// The height the text needs, so the box can grow with it.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = ChipTextView(frame: .zero, textContainer: container)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 3, height: 6)
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        // What is typed is what should be saved.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.setAccessibilityLabel("Expansion")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        proxy.textView = textView
        context.coordinator.load(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent
        coordinator.parent = self
        proxy.textView = coordinator.textView
        coordinator.textView?.isEditable = isEditable
        if text != coordinator.source || isShortForm != old.isShortForm {
            coordinator.load(text)
        } else if signature != old.signature || isMonospaced != old.isMonospaced {
            coordinator.redraw()
        }
        // The width may have changed, and with it where the lines break.
        coordinator.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ExpansionEditor
        weak var textView: ChipTextView?
        weak var scrollView: NSScrollView?
        /// The text as last given to, or taken from, the text view.
        private(set) var source = ""
        private var isUpdating = false
        /// Typing is undone here, apart from the window's own undo of saved changes.
        private let undo = UndoManager()

        init(_ parent: ExpansionEditor) {
            self.parent = parent
        }

        private var attributes: [NSAttributedString.Key: Any] {
            [
                .font: parent.isMonospaced
                    ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                    : NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.textColor,
            ]
        }

        private func chip(for piece: ExpansionPiece) -> NSAttributedString {
            let attachment = ChipAttachment(piece: piece)
            attachment.attachmentCell = ChipCell(style: parent.style(piece))
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
            return string
        }

        private func attributed(_ text: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for piece in ExpansionPiece.pieces(of: text, isShortForm: parent.isShortForm) {
                if piece.isText {
                    result.append(NSAttributedString(string: piece.source, attributes: attributes))
                } else {
                    result.append(chip(for: piece))
                }
            }
            return result
        }

        /// Replaces everything in the text view.
        func load(_ text: String) {
            guard let textView, let storage = textView.textStorage else { return }
            isUpdating = true
            storage.setAttributedString(attributed(text))
            isUpdating = false
            source = text
            textView.typingAttributes = attributes
            undo.removeAllActions()
            reportHeight()
        }

        /// Tells the view how tall the text is.
        func reportHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + textView.textContainerInset.height * 2
            guard abs(height - reportedHeight) > 0.5 else { return }
            reportedHeight = height
            let report = parent.onHeightChange
            // Not during a view update.
            Task { @MainActor in report(height) }
        }

        private var reportedHeight: CGFloat = 0

        /// Draws the chips again, for a changed title, keeping the selection.
        func redraw() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            load(source)
            let length = textView.textStorage?.length ?? 0
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }

        /// The text of a range of the text view, with chips written out.
        func text(in range: NSRange) -> String {
            guard let storage = textView?.textStorage else { return "" }
            var result = ""
            storage.enumerateAttribute(.attachment, in: range) { value, part, _ in
                if let chip = value as? ChipAttachment {
                    result += chip.piece.source
                } else if value == nil {
                    result += (storage.string as NSString).substring(with: part)
                }
            }
            return result
        }

        /// Turns markers that were typed or pasted as text into chips.
        private func makeChips() {
            guard let textView, let storage = textView.textStorage else { return }
            var found: [(range: NSRange, piece: ExpansionPiece)] = []
            let whole = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: whole) { value, range, _ in
                guard value == nil else { return }
                var offset = range.location
                let run = (storage.string as NSString).substring(with: range)
                for piece in ExpansionPiece.pieces(of: run, isShortForm: parent.isShortForm) {
                    let length = (piece.source as NSString).length
                    if !piece.isText { found.append((NSRange(location: offset, length: length), piece)) }
                    offset += length
                }
            }
            guard !found.isEmpty else { return }
            var caret = textView.selectedRange().location
            for item in found.reversed() {
                guard textView.shouldChangeText(in: item.range, replacementString: "\u{FFFC}") else { continue }
                storage.replaceCharacters(in: item.range, with: chip(for: item.piece))
                textView.didChangeText()
                // An insertion point inside or after the marker moves with the text that shrank.
                if caret >= NSMaxRange(item.range) {
                    caret -= item.range.length - 1
                } else if caret > item.range.location {
                    caret = item.range.location + 1
                }
            }
            textView.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView, let storage = textView.textStorage else { return }
            isUpdating = true
            makeChips()
            // Pasted or dragged text may bring its own font along.
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            textView.typingAttributes = attributes
            isUpdating = false
            source = text(in: NSRange(location: 0, length: storage.length))
            parent.onChange(source)
            reportHeight()
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undo
        }

        func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            guard let chip = cell.attachment as? ChipAttachment, let scrollView else { return }
            var rect = textView.convert(cellFrame, to: scrollView)
            if !scrollView.isFlipped {
                rect.origin.y = scrollView.bounds.height - rect.maxY
            }
            textView.setSelectedRange(NSRange(location: charIndex, length: 1))
            parent.onChipClick(chip.piece, rect)
        }
    }
}

/// A text view that copies and pastes chips as the text they stand for.
final class ChipTextView: NSTextView {
    weak var coordinator: ExpansionEditor.Coordinator?

    override func copy(_ sender: Any?) {
        guard let coordinator, selectedRange().length > 0 else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coordinator.text(in: selectedRange()), forType: .string)
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard isEditable, range.length > 0 else { return }
        copy(sender)
        if shouldChangeText(in: range, replacementString: "") {
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
        }
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let coordinator else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(coordinator.text(in: selectedRange()), forType: .string)
    }
}

/// A chip in the text. It remembers the text it stands for.
nonisolated final class ChipAttachment: NSTextAttachment {
    let piece: ExpansionPiece

    init(piece: ExpansionPiece) {
        self.piece = piece
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// Draws a chip: a rounded, tinted box with a symbol and a title.
nonisolated final class ChipCell: NSTextAttachmentCell {
    let style: ChipStyle

    private static var font: NSFont { NSFont.systemFont(ofSize: 12) }
    private static let height: CGFloat = 19
    private static let symbolWidth: CGFloat = 15

    init(style: ChipStyle) {
        self.style = style
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private var tint: NSColor {
        switch style.tone {
        case .cursor: return .controlAccentColor
        case .field: return .systemGreen
        case .variable: return .systemPurple
        case .unknown: return .systemGray
        }
    }

    private var titleSize: NSSize {
        (style.title as NSString).size(withAttributes: [.font: Self.font])
    }

    override func cellSize() -> NSSize {
        NSSize(width: ceil(titleSize.width) + Self.symbolWidth + 6 + 4 + 8 + 2, height: Self.height)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -5)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let tint = self.tint
        let box = cellFrame.insetBy(dx: 1.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        tint.withAlphaComponent(0.16).setFill()
        path.fill()
        tint.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Darker than the tint in light mode and lighter in dark mode, so the title stays readable.
        let ink = tint.blended(withFraction: 0.4, of: .labelColor) ?? tint
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        if let symbol = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let size = symbol.size
            let scale = min(1, (Self.symbolWidth - 1) / max(size.width, 1))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            let origin = NSPoint(
                x: box.minX + 6 + (Self.symbolWidth - drawn.width) / 2,
                y: box.midY - drawn.height / 2
            )
            symbol.draw(
                in: NSRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil
            )
        }
        let title = style.title as NSString
        let size = titleSize
        title.draw(
            at: NSPoint(x: box.minX + 6 + Self.symbolWidth + 4, y: box.midY - size.height / 2),
            withAttributes: [.font: Self.font, .foregroundColor: ink]
        )
    }

    override func wantsToTrackMouse() -> Bool {
        true
    }
}
