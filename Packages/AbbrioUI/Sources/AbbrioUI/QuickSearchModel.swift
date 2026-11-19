import Foundation
public import Observation
import EspansoCLI
public import SnippetModel

/// The state of the Quick Search panel: what is typed, what was found and which row is selected.
@Observable
public final class QuickSearchModel {
    public let model: AppModel
    @ObservationIgnored var inserter: TextInserter
    /// Closes and reopens the panel. The panel's controller sets these.
    @ObservationIgnored var hidePanel: () -> Void = {}
    @ObservationIgnored var showPanel: () -> Void = {}

    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            message = nil
            refreshResults()
        }
    }
    public private(set) var results: [QuickSearchItem] = []
    public var selection = 0
    /// Something the user has to know: a missing permission, or an insertion that failed.
    public private(set) var message: String?
    public private(set) var isInserting = false

    /// False when a test supplied its own timing.
    @ObservationIgnored private let usesPreferredDelay: Bool

    init(model: AppModel, device: any InsertionDevice, timing: InsertionTiming? = nil) {
        self.model = model
        usesPreferredDelay = timing == nil
        inserter = TextInserter(device: device, timing: timing ?? InsertionTiming())
    }

    public var selectedItem: QuickSearchItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    /// A line under the search field when there is nothing to list.
    public var hint: String? {
        guard results.isEmpty else { return nil }
        let typed = query.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty { return "Type to search abbreviations, descriptions and expansions." }
        if typed == "." { return "Nothing has been inserted from Quick Search yet." }
        return "No matches."
    }

    /// What the footer's tag says about the selected item.
    public var routeDescription: String? {
        switch selectedItem?.plan {
        case .paste?: return "pastes the text"
        case .engine(let trigger)?: return "espanso match exec -t \(trigger)"
        case nil: return selectedItem == nil ? nil : "open only"
        }
    }

    /// Starts a fresh search when the panel opens.
    func prepare() {
        query = ""
        message = nil
        model.refreshEngineRecents()
        refreshResults()
        Task { await model.refreshEngine() }
    }

    func refreshResults() {
        results = QuickSearch(sets: model.sets, recents: model.quickSearchRecents).results(for: query)
        selection = 0
    }

    public func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + offset, 0), results.count - 1)
    }

    /// Opens the selected item in the main window's editor.
    public func openSelected() {
        guard let item = selectedItem else { return }
        hidePanel()
        model.reveal(item.id)
    }

    /// Inserts the selected item into the frontmost app. Only one insertion runs at a time.
    public func insertSelected() async {
        guard !isInserting, let item = selectedItem else { return }
        guard let plan = item.plan else {
            message = "A regular expression has no abbreviation to insert. Press ⌘↩ to open it."
            return
        }
        guard inserter.device.isTrusted else {
            inserter.device.askForTrust()
            message = InsertionError.needsAccessibility.message
            return
        }
        if case .engine = plan {
            await model.refreshEngine()
            guard model.isEngineRunning else {
                message = "This item needs Espanso, which isn't running."
                return
            }
        }

        isInserting = true
        defer { isInserting = false }
        if usesPreferredDelay {
            inserter.timing.focusDelay = .milliseconds(model.preferences.insertionDelay)
        }
        hidePanel()
        let client = model.client
        do {
            try await inserter.insert(plan) { trigger in
                guard let client else { throw CommandError.launchFailed("no espanso") }
                try await client.expand(trigger: trigger)
            }
            model.recordUse(of: item.id)
        } catch {
            message = error.message
            showPanel()
        }
    }
}
