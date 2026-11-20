import SwiftUI
import AbbrioUI

/// Brings the main window back when the app is opened again while it runs, which is the only way to reach
/// it when the menu bar icon is hidden and every window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let preferences = Self.model?.preferences else { return }
        preferences.dockIconVisibilityChanged = { showsDockIcon in
            NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
        }
        NSApp.setActivationPolicy(preferences.showsDockIcon ? .regular : .accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editingWindow = sender.windows.first(where: {
            $0.identifier?.rawValue == "main" && ($0.isVisible || $0.isMiniaturized)
        }) else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Close the editing window or quit Abbrio?"
        alert.informativeText = "Closing the editing window keeps Abbrio running. Quitting Abbrio does not stop Espanso."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Close Editing Window")
        alert.addButton(withTitle: "Quit Abbrio")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            editingWindow.performClose(nil)
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.model?.handleReopen(hasVisibleWindows: hasVisibleWindows)
        return true
    }
}

@main
struct AbbrioApp: App {
    @State private var companion: Companion
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let companion = Companion(model: AppModel(
            environment: AbbrioApp.environment(),
            // Hosting the tests must not write anything.
            ownBundleID: Self.isHostingTests ? nil : Bundle.main.bundleIdentifier
        ))
        _companion = State(initialValue: companion)
        AppDelegate.model = companion.model
        // The hotkey and the status must work before any window or menu has been opened.
        if !Self.isHostingTests {
            Task { @MainActor in companion.start() }
        }
    }

    private var model: AppModel { companion.model }

    var body: some Scene {
        Window("Abbrio", id: "main") {
            MainWindow(model: model)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
            CommandGroup(after: .sidebar) {
                Button("Set Info") { model.showSetInfo() }
                    .keyboardShortcut("i")
                    .disabled(!model.canChangeSelectedSet)
            }
            CommandGroup(replacing: .newItem) {
                Button(model.newItemTitle) { model.newItem() }
                    .keyboardShortcut("n")
                    .disabled(!model.canAddItem)
                Button("New Abbreviation Set…") { model.isAskingForNewSetName = true }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.configFolder == nil)
                Button("New Regular Expression Set…") { model.isAskingForNewRegexSetName = true }
                    .disabled(model.configFolder == nil)
            }
            CommandGroup(replacing: .help) {
                ForEach(HelpDestination.allCases) { destination in
                    Button(destination.menuTitle) { destination.open() }
                }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Duplicate") { model.duplicateSelectedItem() }
                    .keyboardShortcut("d")
                    .disabled(!model.canChangeSelectedItem || model.isAddingItem)
                Button("Delete Abbreviation…") { model.requestItemDeletion() }
                    .disabled(!model.canChangeSelectedItem)
            }
        }

        aboutWindow
        appsWindow
        packagesWindow
        statisticsWindow
        quickDefineWindow

        Settings {
            SettingsView(model: model)
        }

        // The icon stays in the menu bar while the app runs, with or without a window open.
        MenuBarExtra(isInserted: Bindable(model.preferences).showsMenuBarIcon) {
            CompanionMenu(companion: companion)
        } label: {
            CompanionLabel(companion: companion)
        }
    }

    private var aboutWindow: some Scene {
        Window("About Abbrio", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private var quickDefineWindow: some Scene {
        Window("New Item", id: "quick-define") {
            QuickDefineView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private var statisticsWindow: some Scene {
        Window("Statistics", id: "statistics") {
            StatisticsWindow(model: model)
        }
        .defaultSize(width: 1100, height: 740)
    }

    private var packagesWindow: some Scene {
        Window("Packages", id: "packages") {
            PackagesWindow(model: model)
        }
        .defaultSize(width: 1000, height: 740)
    }

    private var appsWindow: some Scene {
        Window("Apps", id: "apps") {
            AppsWindow(model: model)
        }
        .defaultSize(width: 1080, height: 760)
    }

    private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static func environment() -> AppEnvironment {
        var environment = AppEnvironment.fromProcess()
        if isHostingTests, environment.configFolderOverride == nil {
            // Unit tests run inside the app. They must never read the user's own config folder.
            environment.configFolderOverride = FileManager.default.temporaryDirectory
                .appendingPathComponent("abbrio-tests-empty-config", isDirectory: true)
            environment.fallbackConfigFolders = []
        }
        return environment
    }
}
