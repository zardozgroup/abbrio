import AppKit
import SwiftUI
import SnippetModel

/// A borderless panel that takes typing without making Abbrio the active app, so the app the user was
/// working in stays in front and gets the inserted text.
final class QuickSearchWindow: NSPanel {
    var onCommandReturn: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shows and hides the Quick Search panel.
final class QuickSearchPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 566
    /// Room around the visible panel for its shadow. Clicks there fall through to what is behind.
    static let margin: CGFloat = 40
    static let height: CGFloat = 470

    let search: QuickSearchModel
    private var panel: QuickSearchWindow?
    /// The search field, so it can be given the keyboard each time the panel opens.
    weak var field: NSTextField?

    init(search: QuickSearchModel) {
        self.search = search
        super.init()
        search.hidePanel = { [weak self] in self?.hide() }
        search.showPanel = { [weak self] in self?.show(keepingQuery: true) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show(keepingQuery: Bool = false) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !keepingQuery { search.prepare() }

        // Top centre of the screen, under the menu bar and the notch.
        // Abbrio is not the active app here, so the screen is taken from the pointer, not from a key window.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let size = NSSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
            panel.setFrame(NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height + Self.margin - 12,
                width: size.width, height: size.height
            ), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        focusField()
    }

    /// Gives the search field the keyboard. The first time the panel opens, SwiftUI may not have put the
    /// field into the window yet; the field then asks again once it is there.
    func focusField() {
        guard let panel, panel.isVisible, let field, field.window === panel else { return }
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickSearchWindow {
        let panel = QuickSearchWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCommandReturn = { [weak self] in self?.search.openSelected() }
        let host = NSHostingView(rootView: QuickSearchView(search: search, controller: self))
        panel.contentView = host
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click in another window puts the panel away, as with Spotlight.
        hide()
    }
}

/// The panel's content: search field, results and the footer.
struct QuickSearchView: View {
    @Bindable var search: QuickSearchModel
    let controller: QuickSearchPanelController

    var body: some View {
        VStack(spacing: 0) {
            panel
            Spacer(minLength: 0)
        }
        .padding(QuickSearchPanelController.margin)
        .frame(
            width: QuickSearchPanelController.width + 2 * QuickSearchPanelController.margin,
            height: QuickSearchPanelController.height + 2 * QuickSearchPanelController.margin
        )
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice {
                noticeBar(notice)
                Divider()
            }
            if search.results.isEmpty {
                Text(search.hint ?? "")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                resultList
            }
            Divider()
            footer
        }
        .frame(width: QuickSearchPanelController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            QuickSearchField(search: search, controller: controller)
                .frame(height: 28)
            if !search.results.isEmpty {
                Text(search.results.count == 1 ? "1 result" : "\(search.results.count) results")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    /// What has to be said above the results: a failed insertion, or that Espanso isn't running.
    private var notice: (text: String, offersStart: Bool)? {
        if let message = search.message {
            return (message, search.model.canStartEngine)
        }
        if search.model.canStartEngine {
            return ("Espanso isn't running. Plain text can still be inserted; other items need Espanso.", true)
        }
        if search.model.engineStatus == .notInstalled {
            return ("Espanso wasn't found. Plain text can still be inserted; other items need Espanso.", false)
        }
        return nil
    }

    private func noticeBar(_ notice: (text: String, offersStart: Bool)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(notice.text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if notice.offersStart {
                Button("Start Espanso") {
                    Task { await search.model.startEngine() }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(search.results.enumerated()), id: \.element.id) { index, item in
                        QuickSearchRow(item: item, isSelected: index == search.selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                search.selection = index
                                if NSEvent.modifierFlags.contains(.command) {
                                    search.openSelected()
                                } else {
                                    Task { await search.insertSelected() }
                                }
                            })
                            .simultaneousGesture(TapGesture().onEnded { search.selection = index })
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(search.results.count), 6.5) * QuickSearchRow.height + 12)
            .onChange(of: search.selection) { _, selection in
                proxy.scrollTo(selection)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("↩ Insert · ⌘↩ Open in editor · esc Close · . Recent")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let route = search.routeDescription {
                Tag(route, .yaml)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }
}

/// One result: the abbreviation, the description over the expansion, and the set.
struct QuickSearchRow: View {
    static let height: CGFloat = 49

    let item: QuickSearchItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(item.abbreviation)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .frame(width: 76, height: 21)
                .background(
                    isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            VStack(alignment: .leading, spacing: 1) {
                if let title = item.title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(item.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                } else {
                    Text(item.preview)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(item.setName)
                .font(.system(size: 11.5))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        // A regular expression can be opened but not inserted.
        .opacity(item.plan == nil && !isSelected ? 0.5 : 1)
        .help(item.plan == nil ? "Regular expressions can only be opened, not inserted." : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A text field that says when it has been put into a window.
final class QuickSearchTextField: NSTextField {
    var onMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }
}

/// The search field. AppKit's field reports the arrow keys, Return and Escape as commands, which is what
/// the panel needs to move the selection while the typing stays in the field.
struct QuickSearchField: NSViewRepresentable {
    let search: QuickSearchModel
    let controller: QuickSearchPanelController

    func makeCoordinator() -> Coordinator { Coordinator(search: search, controller: controller) }

    func makeNSView(context: Context) -> NSTextField {
        let field = QuickSearchTextField()
        field.onMoveToWindow = { [weak controller] in controller?.focusField() }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = "Quick Search"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Quick Search")
        controller.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != search.query { field.stringValue = search.query }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let search: QuickSearchModel
        let controller: QuickSearchPanelController

        init(search: QuickSearchModel, controller: QuickSearchPanelController) {
            self.search = search
            self.controller = controller
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            search.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                search.moveSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)):
                search.moveSelection(by: 1)
            case #selector(NSResponder.insertNewline(_:)):
                Task { await search.insertSelected() }
            case #selector(NSResponder.cancelOperation(_:)):
                controller.hide()
            default:
                return false
            }
            return true
        }
    }
}

#if DEBUG
#Preview("Quick Search") {
    QuickSearchWindowPreview()
}

private struct QuickSearchWindowPreview: View {
    @State private var search = QuickSearchModel(
        model: WindowPreview.makeModel(), device: PreviewInsertionDevice()
    )
    @State private var controller: QuickSearchPanelController?

    var body: some View {
        Group {
            if let controller {
                QuickSearchView(search: search, controller: controller)
            }
        }
        .task {
            if controller == nil {
                controller = QuickSearchPanelController(search: search)
                // The canvas hosts the content itself; it must not open a separate floating panel.
                search.showPanel = {}
            }
        }
    }
}
#endif
