public import Foundation
import AppKit
import ConfigStore
public import SnippetModel

/// The text the Quick Define window starts with.
public nonisolated struct QuickDefineRequest: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case clipboard
        case selection
    }

    public var id = UUID()
    public var source: Source
    public var text: String

    public init(source: Source, text: String) {
        self.source = source
        self.text = text
    }

    public var title: String {
        source == .clipboard ? "New Item from Clipboard" : "New Item from Selection"
    }
}

// Quick Define and the list of recently used items.
extension AppModel {
    private static let recentsKey = "quickSearchRecents"
    private static let lastSetKey = "quickDefineSet"

    static func storedRecentUses(in defaults: UserDefaults) -> [RecentUse] {
        guard let data = defaults.data(forKey: recentsKey) else { return [] }
        return (try? JSONDecoder().decode([RecentUse].self, from: data)) ?? []
    }

    /// Notes that an item was inserted from Quick Search.
    func recordUse(of id: Snippet.ID, at date: Date = Date()) {
        guard let trigger = snippet(with: id)?.triggers.first else { return }
        recentUses = RecentUse.adding(RecentUse(file: id.file, trigger: trigger, date: date), to: recentUses)
        if let data = try? JSONEncoder().encode(recentUses) {
            defaults.set(data, forKey: Self.recentsKey)
        }
    }

    // MARK: Quick Define

    /// The sets a new item can be saved to.
    public var quickDefineSets: [SnippetSet] {
        sets.filter { $0.kind == .abbreviations && !$0.isLocked && !$0.isBroken && !$0.files.isEmpty }
    }

    /// The set the window starts with: the one used last time, else the selected one, else the first.
    public var quickDefineSetID: String? {
        let choices = quickDefineSets
        if let last = defaults.string(forKey: Self.lastSetKey), choices.contains(where: { $0.id == last }) {
            return last
        }
        if let selectedSetID, choices.contains(where: { $0.id == selectedSetID }) { return selectedSetID }
        return choices.first?.id
    }

    /// Opens Quick Define with the text on the clipboard.
    public func defineFromClipboard() {
        guard let text = readClipboard(), !text.isEmpty else {
            presentQuickDefineProblem("The clipboard holds no text.")
            return
        }
        presentQuickDefine(QuickDefineRequest(source: .clipboard, text: text))
    }

    /// Opens Quick Define with the text selected in the frontmost app.
    ///
    /// The selection is read through the Accessibility interface. Apps that don't offer it there are sent
    /// ⌘C instead, and the clipboard is put back afterwards.
    func defineFromSelection(using device: any InsertionDevice, wait: Duration = .milliseconds(400)) async {
        guard device.isTrusted else {
            device.askForTrust()
            presentQuickDefineProblem(
                "Abbrio needs the Accessibility permission to read the selected text. Allow it in System Settings › Privacy & Security › Accessibility, then choose the command again."
            )
            return
        }
        var text = device.selectedText()
        if text == nil {
            let saved = device.saveClipboard()
            // An empty marker makes the copy visible as a change even when the same text is copied again.
            device.setClipboard("")
            let before = device.clipboardChangeCount
            device.copy()
            let deadline = ContinuousClock.now + wait
            while device.clipboardChangeCount == before, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if device.clipboardChangeCount != before {
                text = device.clipboardText()
                // The copy replaced the marker; put the user's clipboard back over it.
                device.setClipboard("")
            }
            device.restoreClipboard(saved)
        }
        guard let text, !text.isEmpty else {
            presentQuickDefineProblem("No text is selected in the frontmost app.")
            return
        }
        presentQuickDefine(QuickDefineRequest(source: .selection, text: text))
    }

    private func presentQuickDefine(_ request: QuickDefineRequest) {
        quickDefine = request
        NSApp?.activate(ignoringOtherApps: true)
        openWindow?("quick-define")
    }

    private func presentQuickDefineProblem(_ message: String) {
        alertMessage = message
        showMainWindow()
    }

    /// The file a set's new items go to, for the window's "Saves to" line.
    public func quickDefinePath(forSet id: String?) -> String? {
        quickDefineSets.first { $0.id == id }?.files.first?.path
    }

    /// The triggers a new item would get: the abbreviation with the set's prefix and suffix, and its case
    /// variants when the set's default is "Case does not matter".
    public func quickDefineTriggers(for abbreviation: String, inSet id: String?) -> [String] {
        guard let set = quickDefineSets.first(where: { $0.id == id }) else { return [] }
        let form = TriggerForm(abbreviation: abbreviation, isCaseInsensitive: set.info.defaultCase == .insensitive)
        return form.triggers(prefix: set.info.prefix, suffix: set.info.suffix)
    }

    /// Writes a new item to a set's file, with the set's default options. Returns an error message, or nil.
    @discardableResult
    public func saveQuickDefine(abbreviation: String, description: String, text: String, setID: String) -> String? {
        guard let set = quickDefineSets.first(where: { $0.id == setID }), let path = set.files.first?.path else {
            return "Choose a set."
        }
        let abbreviation = abbreviation.trimmingCharacters(in: .whitespaces)
        let form = TriggerForm(abbreviation: abbreviation, isCaseInsensitive: set.info.defaultCase == .insensitive)
        var draft = MatchDraft(
            triggers: form.triggers(prefix: set.info.prefix, suffix: set.info.suffix),
            expansion: .text(text),
            label: description.trimmingCharacters(in: .whitespaces)
        )
        draft.options.propagateCase = set.info.defaultCase == .affectsExpansion
        draft.options.word = set.info.defaultExpand == .wordBreak
        if let problem = draft.blockingProblem { return problem }
        guard commitDraft() else { return "Finish the item being edited in the main window first." }

        if !searchText.isEmpty { searchText = "" }
        selectedSetID = setID
        let failure = change(path, named: "New Abbreviation", notes: { sidecar in
            if form.isCaseInsensitive { sidecar.setCaseInsensitive(true, for: abbreviation, in: setID) }
        }) { data throws(EditError) in
            let result = try MatchFileEditor.append(draft, to: data, path: path)
            return (result.data, Snippet.ID(file: path, index: result.index))
        }
        if failure == nil {
            defaults.set(setID, forKey: Self.lastSetKey)
            quickDefine = nil
        }
        return failure
    }
}
