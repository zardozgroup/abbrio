public import Foundation
import AppKit
import Carbon.HIToolbox
public import Observation
public import ConfigStore
public import EspansoCLI
public import SnippetModel

/// Where the app looks for Espanso. Development runs and tests point it at a folder of fixtures.
public nonisolated struct AppEnvironment: Sendable {
    /// Use this config folder and don't ask Espanso where it is.
    public var configFolderOverride: URL?
    /// Use this binary before looking anywhere else.
    public var binaryOverride: URL?
    /// Folders tried, in order, when Espanso can't be asked for its config folder.
    public var fallbackConfigFolders: [URL]

    public init(
        configFolderOverride: URL? = nil,
        binaryOverride: URL? = nil,
        fallbackConfigFolders: [URL] = AppEnvironment.standardConfigFolders
    ) {
        self.configFolderOverride = configFolderOverride
        self.binaryOverride = binaryOverride
        self.fallbackConfigFolders = fallbackConfigFolders
    }

    public static var standardConfigFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/espanso", isDirectory: true),
            home.appendingPathComponent(".config/espanso", isDirectory: true),
        ]
    }

    /// The environment for `espanso` commands. With a config folder override, Espanso is told to use that
    /// folder too, so its answers are about the same files the app shows. Nil passes on the app's own.
    public var engineEnvironment: [String: String]? {
        guard let configFolderOverride else { return nil }
        var variables = ProcessInfo.processInfo.environment
        variables["ESPANSO_CONFIG_DIR"] = configFolderOverride.path
        return variables
    }

    /// Reads the development overrides from the process environment.
    ///
    /// - `ABBRIO_CONFIG_DIR`: use this config folder as it is.
    /// - `ABBRIO_CONFIG_TEMPLATE`: copy this folder to a temporary place and use the copy, so that editing
    ///   never changes the original. This is how the app is run on the fixtures in the repository.
    /// - `ABBRIO_ESPANSO_BINARY`: use this `espanso` program.
    public static func fromProcess() -> AppEnvironment {
        let variables = ProcessInfo.processInfo.environment
        func url(_ name: String, isDirectory: Bool) -> URL? {
            guard let value = variables[name], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: isDirectory)
        }
        var folder = url("ABBRIO_CONFIG_DIR", isDirectory: true)
        if folder == nil, let template = url("ABBRIO_CONFIG_TEMPLATE", isDirectory: true) {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("abbrio-config-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.copyItem(at: template, to: copy)
                folder = copy
            } catch {
                // Without a copy there is nothing safe to edit, so show an empty folder instead of the real one.
                folder = copy
            }
        }
        return AppEnvironment(
            configFolderOverride: folder,
            binaryOverride: url("ABBRIO_ESPANSO_BINARY", isDirectory: false)
        )
    }
}

/// What happened to the last change, shown under the details pane.
public nonisolated enum SaveState: Equatable, Sendable {
    /// Nothing has been changed since the item was opened.
    case idle
    /// The draft can't be saved yet, for example because the abbreviation is empty.
    case invalid(String)
    case saved(EngineConfirmation)
    case failed(String)
    /// The item changed on disk while it was being edited.
    case conflict
}

/// Whether Espanso picked a saved change up.
public nonisolated enum EngineConfirmation: Equatable, Sendable {
    case checking
    case reloaded
    case notRunning
    /// The file is fine, but no reload was seen in Espanso's log.
    case notConfirmed
    /// The set is switched off, so Espanso does not load it.
    case setIsOff
    /// Espanso could not read the config folder after the change.
    case rejected(String)
}

/// The state behind the main window.
@Observable
public final class AppModel {
    public private(set) var sets: [SnippetSet] = []
    public private(set) var configFiles: [ConfigFile] = []
    /// The app's own notes about the folder: set names, prefixes, case modes.
    public private(set) var sidecar = Sidecar()
    public private(set) var duplicates = DuplicateIndex(sets: [])
    public private(set) var configFolder: URL?
    public private(set) var binary: URL?
    /// True when the config folder was named in the environment, as development runs do.
    public var configFolderIsOverridden: Bool { environment.configFolderOverride != nil }
    /// True when the program in use is the one named in Settings or in the environment.
    public private(set) var binaryWasChosen = false
    public private(set) var engineVersion: EngineVersion?
    public internal(set) var engineStatus: EngineStatus = .notRunning
    /// Espanso's guess at the app that holds Secure Input, from its log.
    public internal(set) var secureInputHolder: String?
    /// What went wrong with the last command sent to Espanso from the menu bar or Quick Search.
    public internal(set) var engineMessage: String?
    /// The text waiting in the Quick Define window.
    public var quickDefine: QuickDefineRequest?
    /// Opens one of the app's windows by its identifier. A view hands this over once it has the action.
    @ObservationIgnored public var openWindow: ((String) -> Void)?
    public private(set) var hasLoaded = false

    public var selectedSetID: String? {
        didSet {
            guard selectedSetID != oldValue else { return }
            if searchQuery.isEmpty {
                selectedSnippetID = rows.first?.id
            }
        }
    }
    public var selectedSnippetID: Snippet.ID? {
        didSet {
            guard selectedSnippetID != oldValue, !isAdjustingSelection else { return }
            leaveItem(oldValue)
            beginEditing()
        }
    }
    public var searchText = "" {
        didSet {
            if !rows.contains(where: { $0.id == selectedSnippetID }) {
                selectedSnippetID = rows.first?.id
            }
        }
    }
    public var sortOrder = [KeyPathComparator(\SnippetRow.abbreviation)]

    // MARK: Editing state

    /// The fields of the selected item as the user has them now. Nil when nothing is selected.
    public private(set) var draft: MatchDraft?
    /// The draft's triggers as the form shows them: without the set's prefix and suffix, case variants folded.
    public private(set) var triggerForm: TriggerForm?
    public private(set) var saveState = SaveState.idle
    /// A message for an alert, after something other than an item edit went wrong.
    public var alertMessage: String?
    /// Overrides the saved delay in tests that need to control when autosave runs.
    public var autosaveDelayOverride: Duration?
    /// The window's undo manager, so Edit > Undo reaches file changes.
    public weak var undoManager: UndoManager?

    /// The draft as it was when the item was opened or last saved.
    private var savedDraft: MatchDraft?
    private var savedTriggerForm: TriggerForm?
    /// The item's text in the file when the draft was started.
    private var editingSource: String?
    private var editingID: Snippet.ID?
    private var autosaveTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    /// Parsed match files kept between loads, so a reload parses only the files that changed.
    @ObservationIgnored private let matchFileCache = MatchFileCache()
    private var isAdjustingSelection = false
    /// What the item's text referred to while it is being edited, so undoing a deletion in the text box
    /// brings the variable back.
    @ObservationIgnored var contentMemory = DynamicContentMemory()
    /// The text and variables put aside when the item was switched to a picture, and the picture put aside
    /// when it was switched back, so changing one's mind loses nothing.
    @ObservationIgnored var textStash: (expansion: Expansion, variables: [SnippetVariable], formFields: [ParamEntry])?
    @ObservationIgnored var pictureStash: String?
    private var undoStack: [FileChange] = []
    private var redoStack: [FileChange] = []

    private let environment: AppEnvironment
    let runner: any CommandRunner
    private let locator: EspansoLocator?
    /// The period the Statistics window shows. Changing it does not read anything; the window asks for that.
    public var statisticsPeriod = StatisticsPeriod.today
    public internal(set) var usageReport = UsageReport.empty
    public internal(set) var statisticsSource = StatisticsSource.database
    /// A line for the Statistics window when there is something to explain.
    public internal(set) var statisticsNote: String?
    /// What Espanso recorded last, mapped to the items in the sets.
    @ObservationIgnored var engineRecents: [RecentUse] = []
    /// The app's own preferences.
    public let preferences: AppPreferences
    /// Opens the Settings window. The main window sets this.
    @ObservationIgnored public var openSettings: (() -> Void)?
    @ObservationIgnored var hasHandledLaunchWindow = false
    @ObservationIgnored var wasReopened = false
    let discard: (@Sendable (URL) throws -> Void)?
    private(set) var client: EspansoClient?
    private(set) var engineLog: EngineLog?
    let defaults: UserDefaults
    let isSecureInputOn: @MainActor () -> Bool
    let readClipboard: @MainActor () -> String?
    /// The Hub catalog and what the app is doing with packages.
    public let packageCenter: PackageCenter
    /// The app's own bundle identifier, for the config file that keeps Espanso out of its windows. Nil
    /// leaves that file alone.
    let ownBundleID: String?
    /// What the app last learned about Espanso, put together into `engineStatus`.
    @ObservationIgnored var isEngineRunning = false
    @ObservationIgnored var isPaused = false
    @ObservationIgnored var isSecureInputActive = false
    @ObservationIgnored var logPosition: UInt64?
    @ObservationIgnored var engineTask: Task<Void, Never>?
    /// The Quick Search insertions made by the app, newest first.
    var recentUses: [RecentUse]
    private var isLoading = false

    /// - Parameter discard: How a deleted set's file is removed. The default moves it to the Trash.
    public init(
        environment: AppEnvironment = .fromProcess(),
        runner: any CommandRunner = ProcessRunner(),
        locator: EspansoLocator? = nil,
        discard: (@Sendable (URL) throws -> Void)? = nil,
        defaults: UserDefaults = .standard,
        isSecureInputOn: (@MainActor () -> Bool)? = nil,
        readClipboard: (@MainActor () -> String?)? = nil,
        ownBundleID: String? = nil,
        hub: HubService = .live
    ) {
        self.ownBundleID = ownBundleID
        packageCenter = PackageCenter(service: hub)
        self.defaults = defaults
        self.isSecureInputOn = isSecureInputOn ?? { IsSecureEventInputEnabled() }
        self.readClipboard = readClipboard ?? { NSPasteboard.general.string(forType: .string) }
        recentUses = Self.storedRecentUses(in: defaults)
        self.environment = environment
        self.runner = runner
        self.locator = locator
        preferences = AppPreferences(defaults: defaults)
        self.discard = discard
    }

    // MARK: Loading

    /// Finds Espanso, reads the config folder and refreshes the status.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        // A program named in the environment wins over the one chosen in Settings.
        let locator = self.locator
            ?? EspansoLocator(override: environment.binaryOverride ?? preferences.binaryURL)
        binary = locator.locate()
        binaryWasChosen = locator.override != nil && binary == locator.override
        client = binary.map {
            EspansoClient(executable: $0, runner: runner, environment: environment.engineEnvironment)
        }
        var paths: EnginePaths?
        if let client {
            engineVersion = try? await client.version()
            paths = try? await client.paths()
        } else {
            engineVersion = nil
        }
        engineLog = paths?.runtime.map { EngineLog(runtimeFolder: $0) }

        var folder = environment.configFolderOverride ?? paths?.config
        if folder == nil {
            folder = environment.fallbackConfigFolders.first { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }
        let folderChanged = folder != configFolder
        configFolder = folder

        if let folder {
            apply(await Self.readFolder(folder, cache: matchFileCache))
        } else {
            apply(ConfigSnapshot(root: URL(fileURLWithPath: "/")))
        }
        if folderChanged {
            watch(folder)
        }
        keepExpansionsOutOfOwnWindows()

        await refreshEngine()
    }

    /// Reads the folder again right away, after the app itself changed files.
    func reloadNow() {
        guard let configFolder else { return }
        apply(ConfigLoader(root: configFolder, cache: matchFileCache).load())
    }

    /// Follows changes other programs make in the config folder.
    private func watch(_ folder: URL?) {
        watchTask?.cancel()
        guard let folder else { return }
        let cache = matchFileCache
        watchTask = Task { [weak self] in
            for await _ in ConfigWatcher.changes(in: folder) {
                guard let self else { return }
                self.apply(await Self.readFolder(folder, cache: cache))
            }
        }
    }

    private func apply(_ snapshot: ConfigSnapshot) {
        sets = snapshot.sets
        configFiles = snapshot.configFiles
        sidecar = snapshot.sidecar
        duplicates = DuplicateIndex(sets: snapshot.sets)
        settleSelection()
    }

    /// Keeps the selection valid after the sets changed, and brings the draft in line with the file.
    private func settleSelection() {
        isAdjustingSelection = true
        if selectedSetID == nil || !sets.contains(where: { $0.id == selectedSetID }) {
            selectedSetID = sets.first?.id
        }
        if selectedSnippetID == nil || !rows.contains(where: { $0.id == selectedSnippetID }) {
            selectedSnippetID = rows.first?.id
        }
        isAdjustingSelection = false

        guard selectedSnippetID == editingID,
              draft != nil,
              savedDraft != nil else {
            beginEditing()
            return
        }

        guard !isAddingItem else { return }
        let onDisk = selectedSnippet
        if !hasUnsavedChanges {
            // Nothing typed since the last save: show what the file holds now.
            if onDisk?.source != editingSource {
                beginEditing()
            }
        } else if onDisk?.source != editingSource {
            autosaveTask?.cancel()
            saveState = .conflict
        }
    }

    // MARK: Derived state

    public func sets(ofKind kind: SnippetSet.Kind) -> [SnippetSet] {
        sets.filter { $0.kind == kind }
    }

    public var selectedSet: SnippetSet? {
        sets.first { $0.id == selectedSetID }
    }

    public var searchQuery: SearchQuery {
        SearchQuery(searchText)
    }

    public var isSearching: Bool {
        !searchQuery.isEmpty
    }

    /// The lines of the list: the selected set, or matches from every set while a search is active.
    ///
    /// Views read this several times per update, and a set can hold tens of thousands of items, so the rows
    /// for the last few selections and searches are kept until the sets or match case notes change.
    public var rows: [SnippetRow] {
        let query = searchQuery
        let key = RowCacheKey(
            query: query,
            selectedSetID: query.isEmpty ? selectedSetID : nil,
            sortOrder: sortOrder
        )
        if listCache.sets != sets || listCache.matchNotes != sidecar.matches {
            listCache = ListCache(sets: sets, matchNotes: sidecar.matches)
        }
        var rows: [SnippetRow]
        if let cached = listCache.rows(for: key) {
            rows = cached
        } else {
            rows = buildRows(query: query)
            listCache.store(rows, for: key)
        }
        // The item being added changes with every keystroke, so it is added after the cache.
        if let newItem, query.isEmpty, let set = selectedSet, set.files.first?.path == newItem.id.file {
            rows.append(SnippetRow(
                snippet: newItem, setName: set.name, isDuplicate: false, preview: ExpansionPreview(),
                displayAliases: displayAliases(for: newItem, in: set, draftForm: triggerForm)
            ))
        }
        return rows
    }

    /// What one list of rows was built for. `duplicates` is left out because it is rebuilt whenever `sets` changes.
    private nonisolated struct RowCacheKey: Equatable {
        var query: SearchQuery
        var selectedSetID: String?
        var sortOrder: [KeyPathComparator<SnippetRow>]
    }

    /// Lists built from one version of the sets.
    private nonisolated struct ListCache {
        /// How many lists are kept, so that going back to a set or a search shows it at once.
        static let capacity = 4

        var sets: [SnippetSet] = []
        var matchNotes: [String: [String: MatchNote]] = [:]
        /// The most recently used list last.
        var recent: [(key: RowCacheKey, rows: [SnippetRow])] = []
        /// The search text of every item, by set and position, made when the first search runs.
        var searchTexts: [[String]]?

        mutating func rows(for key: RowCacheKey) -> [SnippetRow]? {
            guard let position = recent.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = recent.remove(at: position)
            recent.append(entry)
            return entry.rows
        }

        mutating func store(_ rows: [SnippetRow], for key: RowCacheKey) {
            recent.append((key, rows))
            if recent.count > Self.capacity { recent.removeFirst() }
        }
    }

    @ObservationIgnored private var listCache = ListCache()

    private func buildRows(query: SearchQuery) -> [SnippetRow] {
        let preview = ExpansionPreview()
        var rows: [SnippetRow] = []
        func add(_ snippet: Snippet, from set: SnippetSet) {
            rows.append(SnippetRow(
                snippet: snippet,
                setName: set.name,
                isDuplicate: !duplicates.conflicts(for: snippet.id).isEmpty,
                preview: preview,
                displayAliases: displayAliases(for: snippet, in: set)
            ))
        }
        if query.isEmpty {
            if let set = selectedSet {
                for snippet in set.snippets { add(snippet, from: set) }
            }
        } else {
            if listCache.searchTexts == nil {
                listCache.searchTexts = sets.map { $0.snippets.map(SearchQuery.searchText(for:)) }
            }
            let searchTexts = listCache.searchTexts ?? []
            for (set, texts) in zip(sets, searchTexts) {
                for (snippet, text) in zip(set.snippets, texts) where query.matches(searchText: text) {
                    add(snippet, from: set)
                }
            }
        }
        rows.sortRows(using: sortOrder)
        return rows
    }

    public func snippet(with id: Snippet.ID?) -> Snippet? {
        guard let id else { return nil }
        if let newItem, newItem.id == id { return newItem }
        for set in sets {
            if let snippet = set.snippets.first(where: { $0.id == id }) {
                return snippet
            }
        }
        return nil
    }

    public var selectedSnippet: Snippet? {
        snippet(with: selectedSnippetID)
    }

    /// Reads the config folder away from the main actor, so a large folder can't stall the window.
    @concurrent
    private nonisolated static func readFolder(_ folder: URL, cache: MatchFileCache) async -> ConfigSnapshot {
        ConfigLoader(root: folder, cache: cache).load()
    }

    /// The set that holds a match.
    public func set(containing id: Snippet.ID) -> SnippetSet? {
        sets.first { set in set.files.contains { $0.path == id.file } }
    }

    /// The footer text under the list, such as "18 items · 1 duplicate trigger: teh is also in AutoCorrect".
    public var listSummary: String {
        let count = rows.count
        var text = count == 1 ? "1 item" : "\(count) items"
        guard !isSearching, let set = selectedSet else { return text }
        let conflicts = duplicates.conflicts(in: set)
        if conflicts.count == 1, let conflict = conflicts.first {
            text += " · 1 duplicate trigger: \(conflict.trigger) "
            text += conflict.otherSetNames.isEmpty
                ? "is used more than once"
                : "is also in " + conflict.otherSetNames.joined(separator: ", ")
        } else if conflicts.count > 1 {
            text += " · \(conflicts.count) duplicate triggers"
        }
        return text
    }

    /// "Abbreviation", "Expansion" or "Description", for the "Sorted by" note.
    public var sortColumnName: String {
        switch sortOrder.first?.keyPath {
        case \SnippetRow.expansion: return "Expansion"
        case \SnippetRow.description: return "Description"
        default: return "Abbreviation"
        }
    }

    // MARK: Editing an item

    /// The position that marks an item that is being added and is not in the file yet.
    private static let newItemIndex = -1

    var writer: ConfigWriter? {
        configFolder.map { ConfigWriter(root: $0) }
    }

    public var isAddingItem: Bool {
        editingID?.index == Self.newItemIndex
    }

    /// The item being added, built from the draft so the list and the details pane can show it.
    private var newItem: Snippet? {
        guard let editingID, isAddingItem, let draft else { return nil }
        return Snippet(
            id: editingID, triggers: draft.triggers, regex: draft.regex, expansion: draft.expansion,
            label: draft.label.isEmpty ? nil : draft.label, searchTerms: draft.searchTerms, options: draft.options,
            variables: draft.variables, formFields: draft.formFields
        )
    }

    /// True when the draft differs from what was last saved.
    public var hasUnsavedChanges: Bool {
        draft != savedDraft || triggerForm != savedTriggerForm
    }

    /// The prefix and suffix of the set that holds the item being edited.
    public var editingAffixes: (prefix: String, suffix: String) {
        guard let editingID, let info = set(containing: editingID)?.info else { return ("", "") }
        return (info.prefix, info.suffix)
    }

    private func triggerForm(for snippet: Snippet) -> TriggerForm? {
        guard !snippet.isRegex, let set = set(containing: snippet.id) else { return nil }
        return triggerForm(for: snippet, in: set)
    }

    private func triggerForm(for snippet: Snippet, in set: SnippetSet) -> TriggerForm {
        let bare = TriggerForm(
            triggers: snippet.triggers, prefix: set.info.prefix, suffix: set.info.suffix, caseInsensitive: false
        )
        guard sidecar.isCaseInsensitive(bare.abbreviation, in: set.id) else { return bare }
        return TriggerForm(
            triggers: snippet.triggers, prefix: set.info.prefix, suffix: set.info.suffix, caseInsensitive: true
        )
    }

    /// An override for rows whose case variants the editor folds. Other rows use the triggers as written.
    private func displayAliases(for snippet: Snippet, in set: SnippetSet, draftForm: TriggerForm? = nil) -> [String]? {
        guard snippet.triggers.count > 1, !snippet.isRegex else { return nil }
        guard draftForm != nil || sidecar.matches[set.id] != nil else { return nil }
        let form = draftForm ?? triggerForm(for: snippet, in: set)
        guard form.isCaseInsensitive else { return nil }
        guard form.usesAffixes else { return form.aliases }
        return form.aliases.map { set.info.prefix + $0 + set.info.suffix }
    }

    /// The choice shown in the Case pop-up.
    public var caseMode: CaseMode {
        if draft?.options.propagateCase == true { return .affectsExpansion }
        return triggerForm?.isCaseInsensitive == true ? .insensitive : .mustMatch
    }

    public func setCaseMode(_ mode: CaseMode) {
        guard draft != nil, formLockReason == nil else { return }
        updateDraft {
            $0.options.propagateCase = mode == .affectsExpansion
            if mode != .affectsExpansion { $0.options.uppercaseStyle = nil }
        }
        updateTriggers { $0.isCaseInsensitive = mode == .insensitive }
        commitDraft()
    }

    /// Changes the abbreviation or aliases as the form shows them. The triggers written to the file follow.
    public func updateTriggers(_ change: (inout TriggerForm) -> Void) {
        guard var form = triggerForm, formLockReason == nil else { return }
        change(&form)
        guard form != triggerForm else { return }
        triggerForm = form
        let affixes = editingAffixes
        let triggers = form.triggers(prefix: affixes.prefix, suffix: affixes.suffix)
        if draft?.triggers == triggers {
            scheduleAutosave()
        } else {
            updateDraft { $0.triggers = triggers }
        }
    }

    /// Why the form is read-only for the selected item. Nil when it can be edited.
    public var formLockReason: String? {
        guard let snippet = selectedSnippet else { return nil }
        if isAddingItem { return nil }
        guard let set = set(containing: snippet.id) else { return nil }
        if set.isLocked { return "Packages can't be edited." }
        if snippet.needsAdvancedYAML {
            return "Advanced YAML. This item can be changed on the YAML tab."
        }
        return nil
    }

    /// True when the selected item's lines can be replaced from the YAML tab.
    public var canEditYAML: Bool {
        guard let snippet = selectedSnippet, !isAddingItem, let set = set(containing: snippet.id) else { return false }
        return !set.isLocked && snippet.sourceRange != nil
    }

    /// Names of other switched-on sets that use one of the draft's triggers.
    public var draftDuplicateSetNames: [String] {
        guard let draft, !draft.isRegex else { return [] }
        let triggers = Set(draft.triggers.filter { !$0.isEmpty })
        var names: [String] = []
        for set in sets where set.isEnabled {
            let clashes = set.snippets.contains { $0.id != editingID && !triggers.isDisjoint(with: $0.triggers) }
            if clashes { names.append(set.name) }
        }
        return names
    }

    private func beginEditing() {
        autosaveTask?.cancel()
        contentMemory = DynamicContentMemory()
        textStash = nil
        pictureStash = nil
        if let snippet = selectedSnippet, !isAddingItem || selectedSnippetID == editingID {
            if isAddingItem { return }
            draft = MatchDraft(snippet)
            savedDraft = draft
            editingSource = snippet.source
            editingID = snippet.id
            triggerForm = triggerForm(for: snippet)
            savedTriggerForm = triggerForm
        } else {
            draft = nil
            savedDraft = nil
            triggerForm = nil
            savedTriggerForm = nil
            editingSource = nil
            editingID = nil
        }
        saveState = .idle
    }

    /// Called when the selection moves away from an item: saves it, or drops an unfinished new item.
    private func leaveItem(_ id: Snippet.ID?) {
        guard let id, id == editingID else { return }
        autosaveTask?.cancel()
        if hasUnsavedChanges, draft?.blockingProblem == nil, saveState != .conflict {
            let selection = selectedSnippetID
            commitDraft()
            // Saving a new item gives it a real position; the selection the user chose stands.
            isAdjustingSelection = true
            selectedSnippetID = selection
            isAdjustingSelection = false
        }
        editingID = nil
    }

    /// Changes the draft. The change is saved after a short pause in typing.
    public func updateDraft(_ change: (inout MatchDraft) -> Void) {
        guard var draft, formLockReason == nil else { return }
        let before = draft
        change(&draft)
        guard draft != before else { return }
        self.draft = draft
        if saveState != .conflict {
            saveState = draft.blockingProblem.map { .invalid($0) } ?? .idle
        }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelayOverride ?? .milliseconds(preferences.autosaveDelay)
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.commitDraft()
        }
    }

    /// Writes the draft to the file now. Returns false when it could not be saved.
    @discardableResult
    public func commitDraft() -> Bool {
        autosaveTask?.cancel()
        guard let draft, let id = editingID, hasUnsavedChanges else { return true }
        guard saveState != .conflict else { return false }
        if let problem = draft.blockingProblem {
            saveState = .invalid(problem)
            return false
        }
        return write(draft, to: id, overwritingOutsideChanges: false)
    }

    private func write(_ draft: MatchDraft, to id: Snippet.ID, overwritingOutsideChanges: Bool) -> Bool {
        guard let writer else { return false }
        do {
            let current = try writer.read(id.file)
            let updated: Data
            var index = id.index
            if isAddingItem {
                (updated, index) = try MatchFileEditor.append(draft, to: current, path: id.file)
            } else {
                if !overwritingOutsideChanges {
                    let onDisk = try? MatchFileParser.parse(String(decoding: current, as: UTF8.self), path: id.file)
                    guard onDisk?.snippets.first(where: { $0.id.index == index })?.source == editingSource else {
                        saveState = .conflict
                        return false
                    }
                }
                updated = try MatchFileEditor.update(matchAt: index, with: draft, in: current, path: id.file)
            }
            let logPosition = engineLog?.position()
            try writer.write(updated, to: id.file, replacing: current)
            let form = triggerForm
            let previous = savedTriggerForm
            let setID = set(containing: id)?.id
            let notes = updateSidecar { sidecar in
                guard let form, let setID else { return }
                if let previous, previous.abbreviation != form.abbreviation {
                    sidecar.setCaseInsensitive(false, for: previous.abbreviation, in: setID)
                }
                sidecar.setCaseInsensitive(form.isCaseInsensitive, for: form.abbreviation, in: setID)
            }
            if updated != current || notes != nil {
                record(FileChange(
                    files: [FileVersion(path: id.file, before: current, after: updated)], notes: notes,
                    name: isAddingItem ? "New Abbreviation" : "Edit Abbreviation"
                ))
            }

            let newID = Snippet.ID(file: id.file, index: index)
            refresh(file: id.file, with: updated)
            isAdjustingSelection = true
            editingID = newID
            if selectedSnippetID == id { selectedSnippetID = newID }
            isAdjustingSelection = false
            savedDraft = draft
            savedTriggerForm = triggerForm
            editingSource = snippet(with: newID)?.source
            saveState = .saved(.checking)
            confirmWithEngine(file: id.file, trigger: draft.triggers.first, logPosition: logPosition)
            return true
        } catch .changedOnDisk {
            saveState = .conflict
            return false
        } catch {
            saveState = .failed(error.message)
            return false
        }
    }

    /// After a conflict: writes the draft over what another program put in the item.
    public func keepMine() {
        guard saveState == .conflict, let draft, let id = editingID else { return }
        if let problem = draft.blockingProblem {
            saveState = .invalid(problem)
            return
        }
        saveState = .idle
        _ = write(draft, to: id, overwritingOutsideChanges: true)
    }

    /// After a conflict: drops the draft and shows what the file holds.
    public func loadFromDisk() {
        guard saveState == .conflict else { return }
        savedDraft = draft
        savedTriggerForm = triggerForm
        reloadNow()
        beginEditing()
    }

    /// Re-parses one file after the app wrote it, without reading the rest of the folder.
    private func refresh(file path: String, with data: Data) {
        guard let position = sets.firstIndex(where: { $0.kind != .package && $0.files.first?.path == path }) else {
            reloadNow()
            return
        }
        var set = sets[position]
        do {
            let parsed = try MatchFileParser.parse(String(decoding: data, as: UTF8.self), path: path)
            set.snippets = parsed.snippets
            set.problems = parsed.problems
            set.globalVariables = parsed.globalVariables
            set.globalVariableList = parsed.globalVariableList
            set.globalVariablesAreEditable = parsed.globalVariablesAreComplete
        } catch {
            reloadNow()
            return
        }
        if !set.snippets.isEmpty {
            set.kind = set.snippets.allSatisfy(\.isRegex) ? .regularExpressions : .abbreviations
        }
        sets[position] = set
        duplicates = DuplicateIndex(sets: sets)
    }

    // MARK: Items

    /// True when items can be added to the selected set from the form.
    public var canAddItem: Bool {
        guard let set = selectedSet, !isSearching else { return false }
        return !set.isLocked && !set.isBroken
    }

    /// Starts a new item in the selected set. It is written once it has an abbreviation.
    public func newItem(in setID: String? = nil) {
        if let setID { selectedSetID = setID }
        guard canAddItem, let set = selectedSet, let file = set.files.first else { return }
        commitDraft()
        let id = Snippet.ID(file: file.path, index: Self.newItemIndex)
        var draft = set.kind == .regularExpressions
            ? MatchDraft(regex: "", expansion: .text(""))
            : MatchDraft(triggers: [""], expansion: .text(""))
        var form: TriggerForm?
        if !draft.isRegex {
            // The set's defaults for new items.
            draft.options.propagateCase = set.info.defaultCase == .affectsExpansion
            draft.options.word = set.info.defaultExpand == .wordBreak
            form = TriggerForm(isCaseInsensitive: set.info.defaultCase == .insensitive)
        }
        contentMemory = DynamicContentMemory()
        textStash = nil
        pictureStash = nil
        isAdjustingSelection = true
        self.draft = draft
        savedDraft = draft
        triggerForm = form
        savedTriggerForm = form
        editingSource = nil
        editingID = id
        selectedSnippetID = id
        isAdjustingSelection = false
        saveState = .idle
    }

    /// True when the selected item is in a file the app may change.
    public var canChangeSelectedItem: Bool {
        guard let snippet = selectedSnippet, let set = set(containing: snippet.id) else { return false }
        return isAddingItem || (!set.isLocked && snippet.sourceRange != nil)
    }

    /// Copies the selected item, as written, to the line below it.
    public func duplicateSelectedItem() {
        guard canChangeSelectedItem, !isAddingItem, commitDraft(), let id = selectedSnippetID else { return }
        change(id.file, named: "Duplicate Abbreviation") { data throws(EditError) in
            let result = try MatchFileEditor.duplicate(matchAt: id.index, in: data, path: id.file)
            return (result.data, Snippet.ID(file: id.file, index: result.index))
        }
    }

    /// Removes the selected item from its file.
    public func deleteSelectedItem() {
        guard canChangeSelectedItem, let id = selectedSnippetID else { return }
        if isAddingItem {
            editingID = nil
            draft = nil
            savedDraft = nil
            triggerForm = nil
            savedTriggerForm = nil
            selectedSnippetID = rows.first?.id
            return
        }
        autosaveTask?.cancel()
        savedDraft = draft
        let neighbour = rowID(after: id)
        let abbreviation = savedTriggerForm?.abbreviation
        let setID = set(containing: id)?.id
        savedTriggerForm = triggerForm
        change(id.file, named: "Delete Abbreviation", notes: { sidecar in
            if let abbreviation, let setID { sidecar.setCaseInsensitive(false, for: abbreviation, in: setID) }
        }) { data throws(EditError) in
            (try MatchFileEditor.delete(matchAt: id.index, in: data, path: id.file), neighbour)
        }
    }

    /// The item to select once `id` is gone: the next row, or the one before. Later items move up one place.
    private func rowID(after id: Snippet.ID) -> Snippet.ID? {
        let rows = rows
        guard let position = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let other = position + 1 < rows.count ? rows[position + 1].id : (position > 0 ? rows[position - 1].id : nil)
        guard var other else { return nil }
        if other.file == id.file, other.index > id.index { other.index -= 1 }
        return other
    }

    /// Replaces the selected item's lines with YAML the user wrote. Returns an error message, or nil.
    public func saveYAML(_ text: String) -> String? {
        guard canEditYAML, let id = selectedSnippetID else { return "This item can't be changed." }
        autosaveTask?.cancel()
        savedDraft = draft
        savedTriggerForm = triggerForm
        return change(id.file, named: "Edit YAML") { data throws(EditError) in
            (try MatchFileEditor.replaceSource(ofMatchAt: id.index, with: text, in: data, path: id.file), id)
        }
    }

    /// The whole text of a set's file, for fixing a file that can't be parsed.
    public func fileText(of set: SnippetSet) -> String? {
        guard let path = set.files.first?.path, let data = try? writer?.read(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces a set's whole file. Returns an error message, or nil.
    public func saveFileText(_ text: String, of set: SnippetSet) -> String? {
        guard !set.isLocked, let path = set.files.first?.path else { return "This file can't be changed." }
        return change(path, named: "Edit YAML") { _ throws(EditError) in
            try MatchFileEditor.validate(fileText: text, path: path)
            return (Data(text.utf8), nil)
        }
    }

    /// Reads a file, applies a change, writes it and brings the window up to date. Returns an error message.
    @discardableResult
    func change(
        _ path: String, named name: String, notes: ((inout Sidecar) -> Void)? = nil,
        _ edit: (Data) throws(EditError) -> (data: Data, selection: Snippet.ID?)
    ) -> String? {
        guard let writer else { return "No config folder." }
        do {
            let current = try writer.read(path)
            let result = try edit(current)
            let logPosition = engineLog?.position()
            try writer.write(result.data, to: path, replacing: current)
            let noteChange = notes.flatMap { updateSidecar($0) }
            record(FileChange(
                files: [FileVersion(path: path, before: current, after: result.data)], notes: noteChange, name: name
            ))
            isAdjustingSelection = true
            editingID = nil
            isAdjustingSelection = false
            refresh(file: path, with: result.data)
            isAdjustingSelection = true
            selectedSnippetID = result.selection
            isAdjustingSelection = false
            settleSelection()
            beginEditing()
            saveState = .saved(.checking)
            confirmWithEngine(file: path, trigger: nil, logPosition: logPosition)
            return nil
        } catch {
            saveState = .failed(error.message)
            return error.message
        }
    }

    // MARK: Undo

    private struct FileVersion {
        var path: String
        var before: Data
        var after: Data
    }

    /// One step for Undo: the files it changed and, when it touched them, the app's notes.
    private struct FileChange {
        var files: [FileVersion]
        var notes: (before: Data?, after: Data?)?
        var name: String
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func record(_ change: FileChange) {
        undoStack.append(change)
        redoStack.removeAll()
        registerWithUndoManager(change, isRedo: false)
    }

    private func registerWithUndoManager(_ change: FileChange, isRedo: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if isRedo { model.redo() } else { model.undo() }
            }
        }
        undoManager.setActionName(change.name)
    }

    /// Puts the files back as they were before the last change the app made.
    public func undo() {
        commitDraft()
        guard let change = undoStack.popLast() else { return }
        if restore(change, undoing: true) {
            redoStack.append(change)
            registerWithUndoManager(change, isRedo: true)
        }
    }

    public func redo() {
        guard let change = redoStack.popLast() else { return }
        if restore(change, undoing: false) {
            undoStack.append(change)
            registerWithUndoManager(change, isRedo: false)
        }
    }

    private func restore(_ change: FileChange, undoing: Bool) -> Bool {
        guard let writer, let configFolder else { return false }
        // Nothing is put back unless every file still holds what the change left there.
        for file in change.files {
            let expected = undoing ? file.after : file.before
            guard (try? writer.read(file.path)) == expected else {
                alertMessage = "\(file.path) was changed by another program, so the change can't be undone."
                return false
            }
        }
        do {
            let logPosition = engineLog?.position()
            for file in change.files {
                try writer.write(undoing ? file.before : file.after, to: file.path, replacing: undoing ? file.after : file.before)
            }
            if let notes = change.notes {
                try SidecarStore(root: configFolder).write(undoing ? notes.before : notes.after)
            }
            isAdjustingSelection = true
            editingID = nil
            isAdjustingSelection = false
            reloadNow()
            beginEditing()
            saveState = .saved(.checking)
            confirmWithEngine(file: change.files.first?.path ?? "", trigger: nil, logPosition: logPosition)
            return true
        } catch {
            alertMessage = error.message
            return false
        }
    }

    /// Changes the app's notes and saves them. Returns the file's bytes before and after when something
    /// changed, for Undo.
    @discardableResult
    func updateSidecar(_ change: (inout Sidecar) -> Void) -> (before: Data?, after: Data?)? {
        guard let configFolder else { return nil }
        var updated = sidecar
        change(&updated)
        guard updated != sidecar else { return nil }
        let store = SidecarStore(root: configFolder)
        let before = store.data()
        do {
            try store.save(updated)
        } catch {
            alertMessage = error.message
            return nil
        }
        sidecar = updated
        return (before, store.data())
    }

    /// File changes can't be undone once the file has another name or is gone.
    private func forgetChanges(to path: String) {
        undoStack.removeAll { $0.files.contains { $0.path == path } }
        redoStack.removeAll { $0.files.contains { $0.path == path } }
    }

    // MARK: Sets

    private var setManager: SetManager? {
        guard let writer else { return nil }
        if let discard { return SetManager(writer: writer, discard: discard) }
        return SetManager(writer: writer)
    }

    /// Creates an empty set and selects it. Returns false when it could not be created.
    @discardableResult
    public func createSet(named name: String, forRegularExpressions: Bool = false) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        return changeSets(notes: { sidecar, outcome in
            guard let id = outcome.id else { return }
            var info = sidecar.info(for: id)
            info.name = Self.storedName(name, forSet: id)
            // The file starts empty, so only the app's notes can say what it is for.
            info.holdsRegularExpressions = forRegularExpressions ? true : nil
            sidecar.setInfo(info, for: id)
        }) { manager throws(EditError) in try manager.createSet(named: name) }
    }

    /// Creates a set that holds the given items, as when a list is imported.
    @discardableResult
    func createSet(named name: String, holding drafts: [MatchDraft]) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        return changeSets(notes: { sidecar, outcome in
            guard let id = outcome.id else { return }
            var info = sidecar.info(for: id)
            info.name = Self.storedName(name, forSet: id)
            sidecar.setInfo(info, for: id)
        }) { manager throws(EditError) in try manager.createSet(named: name, holding: drafts) }
    }

    /// The name to remember for a set. Nil when the file name already says it.
    private static func storedName(_ name: String, forSet id: String) -> String? {
        name == SnippetSet.displayName(forFileName: (id as NSString).lastPathComponent) ? nil : name
    }

    /// Gives a set another name. The file keeps its name unless `renamingFile` is true.
    @discardableResult
    public func renameSet(_ id: String, to name: String, renamingFile: Bool) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, sets.contains(where: { $0.id == id && !$0.isLocked }) else { return false }
        if renamingFile, renameWouldChangeFile(id, to: name) {
            return changeSets(forgetting: id, notes: { sidecar, outcome in
                guard let newID = outcome.id else { return }
                sidecar.moveSet(from: id, to: newID)
                var info = sidecar.info(for: newID)
                info.name = Self.storedName(name, forSet: newID)
                sidecar.setInfo(info, for: newID)
            }) { manager throws(EditError) in try manager.renameSet(id, to: name) }
        }
        commitDraft()
        updateSidecar { sidecar in
            var info = sidecar.info(for: id)
            info.name = Self.storedName(name, forSet: id)
            sidecar.setInfo(info, for: id)
        }
        reloadNow()
        return true
    }

    /// True when renaming the file after `name` would give it another file name.
    public func renameWouldChangeFile(_ id: String, to name: String) -> Bool {
        fileName(forSetNamed: name, renaming: id) != (id as NSString).lastPathComponent
    }

    /// Switches a set on or off in all applications.
    @discardableResult
    public func setEnabled(_ enabled: Bool, for id: String) -> Bool {
        changeSets(forgetting: id, notes: { sidecar, outcome in
            if let newID = outcome.id { sidecar.moveSet(from: id, to: newID) }
        }) { manager throws(EditError) in try manager.setEnabled(enabled, for: id) }
    }

    /// Moves a set's file to the Trash.
    @discardableResult
    public func deleteSet(_ id: String) -> Bool {
        changeSets(forgetting: id, notes: { sidecar, _ in sidecar.removeSet(id) }) { manager throws(EditError) in
            try manager.deleteSet(id)
        }
    }

    /// Copies a set's file and what the app knows about it, and selects the copy.
    @discardableResult
    public func duplicateSet(_ id: String) -> Bool {
        guard let set = sets.first(where: { $0.id == id }), !set.isLocked else { return false }
        return changeSets(notes: { sidecar, outcome in
            guard let newID = outcome.id else { return }
            var info = sidecar.info(for: id)
            info.name = set.name + " copy"
            info.order = nil
            sidecar.setInfo(info, for: newID)
            if let notes = sidecar.matches[id] { sidecar.matches[newID] = notes }
        }) { manager throws(EditError) in try manager.duplicateSet(id) }
    }

    /// Rearranges the sets of one sidebar section. The order is the app's own; Espanso doesn't see it.
    public func moveSets(ofKind kind: SnippetSet.Kind, fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = sets(ofKind: kind).map(\.id)
        let moved = source.sorted().map { ids[$0] }
        let insertion = destination - source.count(in: 0..<destination)
        ids.removeAll { moved.contains($0) }
        ids.insert(contentsOf: moved, at: min(max(insertion, 0), ids.count))
        updateSidecar { sidecar in
            for (position, id) in ids.enumerated() {
                var info = sidecar.info(for: id)
                info.order = position
                sidecar.setInfo(info, for: id)
            }
        }
        reloadNow()
    }

    /// The file name a set would get, for the confirmation before renaming.
    public func fileName(forSetNamed name: String, renaming id: String) -> String {
        let current = (id as NSString).lastPathComponent
        let fileExtension = (current as NSString).pathExtension
        return (current.hasPrefix("_") ? "_" : "") + SetManager.slug(for: name) + "." + (fileExtension.isEmpty ? "yml" : fileExtension)
    }

    private func changeSets(
        forgetting id: String? = nil,
        notes: ((inout Sidecar, SetManager.Outcome) -> Void)? = nil,
        _ operation: (SetManager) throws(EditError) -> SetManager.Outcome
    ) -> Bool {
        guard let setManager else { return false }
        commitDraft()
        let wasSelected = id == nil || selectedSetID == id
        do {
            let outcome = try operation(setManager)
            if let id, let path = sets.first(where: { $0.id == id })?.files.first?.path {
                forgetChanges(to: path)
            }
            if let notes {
                updateSidecar { notes(&$0, outcome) }
            }
            isAdjustingSelection = true
            editingID = nil
            isAdjustingSelection = false
            reloadNow()
            if wasSelected, let newID = outcome.id, sets.contains(where: { $0.id == newID }) {
                selectedSetID = newID
            }
            if !outcome.remainingReferences.isEmpty {
                alertMessage = "These files still mention the old file name and need a look: "
                    + outcome.remainingReferences.joined(separator: ", ")
            }
            return true
        } catch {
            alertMessage = error.message
            return false
        }
    }

    // MARK: Set Info

    /// What changing a set's prefix and suffix would do.
    public struct AffixPreview: Equatable, Sendable {
        /// The first few triggers as they would be written.
        public var examples: [String] = []
        /// How many triggers would be rewritten.
        public var count = 0
        /// Items the form can't rewrite. The change is refused while there are any.
        public var blockedItems: [String] = []
        /// True when every trigger already starts and ends with the new prefix and suffix, so they could be
        /// taken as the set's existing ones without rewriting anything.
        public var canAdopt = false
    }

    public func affixPreview(for id: String, prefix: String, suffix: String) -> AffixPreview {
        var preview = AffixPreview()
        guard let set = sets.first(where: { $0.id == id }) else { return preview }
        let old = (set.info.prefix, set.info.suffix)
        guard old != (prefix, suffix) else { return preview }
        let items = set.snippets.filter { !$0.isRegex }
        let triggers = items.flatMap(\.triggers)
        for snippet in items {
            let new = snippet.triggers.map { TriggerForm.reaffix($0, from: old, to: (prefix, suffix)) }
            guard new != snippet.triggers else { continue }
            preview.count += new.count
            if preview.examples.count < 3 { preview.examples.append(new[0]) }
            if snippet.needsAdvancedYAML { preview.blockedItems.append(snippet.abbreviation) }
        }
        let prefixIsNew = prefix != old.0, suffixIsNew = suffix != old.1
        preview.canAdopt = !triggers.isEmpty
            && (!prefixIsNew || old.0.isEmpty) && (!suffixIsNew || old.1.isEmpty)
            && triggers.allSatisfy { TriggerForm.carries($0, prefix: prefixIsNew ? prefix : "", suffix: suffixIsNew ? suffix : "") }
        return preview
    }

    /// Saves what the Set Info sheet holds. Returns an error message, or nil.
    ///
    /// - Parameters:
    ///   - adoptingAffixes: Take the new prefix and suffix as ones the triggers already have, without
    ///     rewriting the file.
    ///   - renamingFile: Also rename the file after the new name.
    public func applySetInfo(
        _ info: SetInfo, name: String, to id: String, adoptingAffixes: Bool = false, renamingFile: Bool = false
    ) -> String? {
        guard let writer, let set = sets.first(where: { $0.id == id }), !set.isLocked,
              let path = set.files.first?.path
        else { return "This set can't be changed." }
        commitDraft()
        let name = name.trimmingCharacters(in: .whitespaces)
        var info = info
        info.name = name.isEmpty ? set.info.name : Self.storedName(name, forSet: id)
        info.order = set.info.order

        let old = (set.info.prefix, set.info.suffix)
        let new = (info.prefix, info.suffix)
        var files: [FileVersion] = []
        var logPosition: UInt64?
        if old != new, !adoptingAffixes, !set.isBroken {
            var triggers: [Int: [String]] = [:]
            for snippet in set.snippets where !snippet.isRegex {
                triggers[snippet.id.index] = snippet.triggers.map { TriggerForm.reaffix($0, from: old, to: new) }
            }
            do {
                let current = try writer.read(path)
                let updated = try MatchFileEditor.replaceTriggers(triggers, in: current, path: path)
                logPosition = engineLog?.position()
                try writer.write(updated, to: path, replacing: current)
                if updated != current { files.append(FileVersion(path: path, before: current, after: updated)) }
            } catch {
                return error.message
            }
        }
        let notes = updateSidecar { $0.setInfo(info, for: id) }
        if !files.isEmpty {
            record(FileChange(files: files, notes: notes, name: "Change Prefix"))
        }
        isAdjustingSelection = true
        editingID = nil
        isAdjustingSelection = false
        reloadNow()
        beginEditing()
        if !files.isEmpty {
            saveState = .saved(.checking)
            confirmWithEngine(file: path, trigger: nil, logPosition: logPosition)
        }
        if renamingFile, !name.isEmpty, renameWouldChangeFile(id, to: name) {
            guard renameSet(id, to: name, renamingFile: true) else { return alertMessage ?? "The file could not be renamed." }
        }
        return nil
    }

    // MARK: Moving items between sets

    /// Moves or copies items to the end of another set. Returns false when nothing was changed.
    @discardableResult
    public func moveItems(_ ids: [Snippet.ID], toSet targetID: String, copying: Bool) -> Bool {
        guard let writer, let target = sets.first(where: { $0.id == targetID }), !target.isLocked, !target.isBroken,
              let targetPath = target.files.first?.path
        else { return false }
        commitDraft()
        let ids = ids.filter { id in
            id.file != targetPath && id.index >= 0 && (copying || set(containing: id)?.isLocked == false)
        }
        .sorted { ($0.file, $0.index) < ($1.file, $1.index) }
        guard !ids.isEmpty else { return false }

        do {
            let targetBefore = try writer.read(targetPath)
            var targetData = targetBefore
            var sources: [String: (before: Data, after: Data)] = [:]
            var carriedNotes: [String] = []
            for id in ids {
                let source = try sources[id.file]?.before ?? writer.read(id.file)
                sources[id.file] = sources[id.file] ?? (source, source)
                targetData = try MatchFileEditor.copy(
                    matchAt: id.index, from: source, path: id.file, to: targetData, path: targetPath
                ).data
                if let snippet = snippet(with: id), let form = triggerForm(for: snippet), form.isCaseInsensitive {
                    carriedNotes.append(form.abbreviation)
                }
            }
            if !copying {
                // From the bottom up, so the positions of the items above stay valid.
                for id in ids.reversed() {
                    guard let source = sources[id.file] else { continue }
                    sources[id.file]?.after = try MatchFileEditor.delete(matchAt: id.index, in: source.after, path: id.file)
                }
            }
            let logPosition = engineLog?.position()
            try writer.write(targetData, to: targetPath, replacing: targetBefore)
            var files = [FileVersion(path: targetPath, before: targetBefore, after: targetData)]
            if !copying {
                for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
                    try writer.write(source.after, to: path, replacing: source.before)
                    files.append(FileVersion(path: path, before: source.before, after: source.after))
                }
            }
            let notes = updateSidecar { sidecar in
                for abbreviation in carriedNotes { sidecar.setCaseInsensitive(true, for: abbreviation, in: targetID) }
            }
            record(FileChange(files: files, notes: notes, name: copying ? "Copy to Set" : "Move to Set"))
            isAdjustingSelection = true
            editingID = nil
            isAdjustingSelection = false
            reloadNow()
            beginEditing()
            saveState = .saved(.checking)
            confirmWithEngine(file: targetPath, trigger: nil, logPosition: logPosition)
            return true
        } catch {
            reloadNow()
            alertMessage = (error as? EditError)?.message ?? error.localizedDescription
            return false
        }
    }

    // MARK: Requests from menus and buttons

    /// True while the window asks for the name of a new set.
    public var isAskingForNewSetName = false
    public var isAskingForNewRegexSetName = false
    /// Sample text for the rule tester, per item, for as long as the app runs.
    var regexSamples: [Snippet.ID: String] = [:]
    /// True while the window asks whether to delete the selected item.
    public var isConfirmingItemDeletion = false
    /// The set the window is asking about before moving it to the Trash.
    public var setAwaitingDeletion: String?
    /// The set whose Set Info sheet is open.
    public var setShowingInfo: String?
    /// A list read from a file, shown in the import sheet until it is imported or dismissed.
    public var pendingImport: PendingImport?
    /// The tab the Packages window shows.
    public var packagesTab = PackagesTab.installed
    /// True while the Packages window asks for a git repository to install from.
    public var isAskingForGitInstall = false
    /// The set whose package export sheet is open.
    public var setBeingExported: String?

    /// Opens Set Info for a set, or for the selected one.
    public func showSetInfo(for id: String? = nil) {
        guard let id = id ?? selectedSetID, sets.contains(where: { $0.id == id && !$0.isLocked }) else { return }
        commitDraft()
        setShowingInfo = id
    }

    /// Asks before deleting the selected item. An item that was never saved just goes away.
    public func requestItemDeletion() {
        guard canChangeSelectedItem else { return }
        if isAddingItem {
            deleteSelectedItem()
        } else {
            isConfirmingItemDeletion = true
        }
    }

    /// True when the selected set's file may be renamed, switched or removed.
    public var canChangeSelectedSet: Bool {
        selectedSet.map { !$0.isLocked } ?? false
    }

    // MARK: Checking with Espanso

    /// After a save: asks Espanso whether the folder still loads and waits for its log to show a reload.
    private func confirmWithEngine(file path: String, trigger: String?, logPosition: UInt64?) {
        confirmationTask?.cancel()
        let client = client
        let log = engineLog
        let fileName = (path as NSString).lastPathComponent
        confirmationTask = Task { [weak self] in
            let result = await Self.confirmation(
                client: client, log: log, logPosition: logPosition, setIsOff: fileName.hasPrefix("_")
            )
            guard !Task.isCancelled, let self, self.saveState == .saved(.checking) else { return }
            self.saveState = .saved(result)
            switch result {
            case .reloaded: self.setEngineRunning(true)
            case .notRunning where self.client != nil: self.setEngineRunning(false)
            default: break
            }
        }
    }

    private static func confirmation(
        client: EspansoClient?, log: EngineLog?, logPosition: UInt64?, setIsOff: Bool
    ) async -> EngineConfirmation {
        guard let client else { return .notRunning }
        do {
            _ = try await client.loadedTriggers()
        } catch CommandError.failed(_, let message) {
            let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
            return .rejected(firstLine)
        } catch {
            return .notConfirmed
        }
        if setIsOff { return .setIsOff }
        guard await client.isRunning() else { return .notRunning }
        guard let log, let logPosition else { return .notConfirmed }
        return await log.waitForReload(since: logPosition) ? .reloaded : .notConfirmed
    }
}
