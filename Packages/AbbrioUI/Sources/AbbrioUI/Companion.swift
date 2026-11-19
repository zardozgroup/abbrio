import AppKit
import KeyboardShortcuts
public import SwiftUI
import SnippetModel

extension KeyboardShortcuts.Name {
    /// Opens Quick Search from any app. ⌃⌘S unless changed in Settings.
    static let quickSearch = Self("quickSearch", default: .init(.s, modifiers: [.control, .command]))
    /// The two Quick Define commands have no shortcut until one is recorded in Settings.
    static let defineFromClipboard = Self("defineFromClipboard")
    static let defineFromSelection = Self("defineFromSelection")
}

/// The parts of the app that work without its main window: the menu bar icon's commands, the Quick Search
/// panel and its hotkey.
public final class Companion {
    public let model: AppModel
    public let search: QuickSearchModel
    let device: any InsertionDevice
    private let panel: QuickSearchPanelController
    private var hasStarted = false

    public init(model: AppModel) {
        self.model = model
        let device = SystemInsertionDevice()
        self.device = device
        search = QuickSearchModel(model: model, device: device)
        panel = QuickSearchPanelController(search: search)
    }

    /// Registers the hotkey and starts following Espanso's state. Does nothing the second time.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        KeyboardShortcuts.onKeyDown(for: .quickSearch) { [weak self] in
            self?.toggleQuickSearch()
        }
        KeyboardShortcuts.onKeyDown(for: .defineFromClipboard) { [weak self] in
            self?.model.defineFromClipboard()
        }
        KeyboardShortcuts.onKeyDown(for: .defineFromSelection) { [weak self] in
            self?.defineFromSelection()
        }
        model.followEngine()
        Task { [model] in
            if !model.hasLoaded { await model.load() }
        }
    }

    public func toggleQuickSearch() {
        panel.toggle()
    }

    public func showQuickSearch() {
        panel.show()
    }

    public func defineFromSelection() {
        Task { [model, device] in
            // The menu has to close before the frontmost app can be asked for its selection.
            try? await Task.sleep(for: .milliseconds(150))
            await model.defineFromSelection(using: device)
        }
    }
}

/// The icon in the menu bar.
public struct CompanionLabel: View {
    let companion: Companion
    @Environment(\.openWindow) private var openWindow

    public init(companion: Companion) {
        self.companion = companion
    }

    public var body: some View {
        Image(nsImage: MenuBarGlyph.image(for: companion.model.engineStatus))
            .onAppear {
                companion.model.openWindow = { [openWindow] id in openWindow(id: id) }
            }
    }
}

/// The menu under the menu bar icon.
public struct CompanionMenu: View {
    let companion: Companion
    @Environment(\.openWindow) private var openWindow

    public init(companion: Companion) {
        self.companion = companion
    }

    private var model: AppModel { companion.model }

    public var body: some View {
        Group {
            header
            Divider()
            Button("Quick Search…") { companion.showQuickSearch() }
                .keyboardShortcut(Self.menuShortcut(for: .quickSearch))
            Button("New Item from Clipboard…") {
                prepareWindows()
                model.defineFromClipboard()
            }
            .disabled(model.quickDefineSets.isEmpty)
            Button("New Item from Selection…") {
                prepareWindows()
                companion.defineFromSelection()
            }
            .disabled(model.quickDefineSets.isEmpty)
            Divider()
            if model.expansionsArePaused {
                Button("Resume Expansions") { Task { await model.resumeExpansions() } }
            } else {
                Button("Pause Expansions") { Task { await model.pauseExpansions() } }
                    .disabled(!model.canPauseOrResume)
            }
            Divider()
            Button("Open Main Window") {
                prepareWindows()
                model.showMainWindow()
            }
            Button("Restart Espanso") { Task { await model.restartEngine() } }
                .disabled(model.engineStatus == .notInstalled)
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Abbrio") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var header: some View {
        Label {
            Text(headline)
        } icon: {
            Image(nsImage: Self.dot(for: model.engineStatus))
        }
        .labelStyle(.titleAndIcon)
        if model.canStartEngine {
            Button("Start Espanso") { Task { await model.startEngine() } }
        }
        if let message = model.engineMessage {
            Text(message)
        }
    }

    /// The recorded shortcut in the form a menu item shows, when it is a letter or digit with modifiers.
    static func menuShortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcut? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name),
              let character = shortcut.description.last, character.isLetter || character.isNumber
        else { return nil }
        var modifiers: EventModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(Character(character.lowercased())), modifiers: modifiers)
    }

    private var headline: String {
        guard let version = model.engineVersion, model.engineStatus != .notInstalled else {
            return model.engineHeadline
        }
        return "\(model.engineHeadline) — \(version)"
    }

    private func prepareWindows() {
        model.openWindow = { [openWindow] id in openWindow(id: id) }
    }

    /// The colored dot in front of the status line.
    static func dot(for status: EngineStatus) -> NSImage {
        let color: NSColor
        switch status {
        case .running: color = .systemGreen
        case .paused, .secureInput: color = .systemOrange
        case .notRunning, .notInstalled: color = .systemRed
        }
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
