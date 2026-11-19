import AppKit
import EspansoCLI
import Foundation
public import SnippetModel

// Espanso's state and the commands sent to it from the menu bar.
extension AppModel {
    /// The first line of the menu bar menu.
    public var engineHeadline: String {
        switch engineStatus {
        case .running: return "Espanso is running"
        case .paused: return "Expansions paused"
        case .secureInput:
            // Espanso only guesses at the app, so the name is given as likely, not certain.
            if let secureInputHolder { return "Secure Input is on, probably in \(secureInputHolder)" }
            return "Secure Input is on"
        case .notRunning: return "Espanso isn't running"
        case .notInstalled: return "Espanso wasn't found"
        }
    }

    /// True when a Start Espanso control makes sense.
    public var canStartEngine: Bool { engineStatus == .notRunning }

    /// True while the app knows expansions to be switched off.
    public var expansionsArePaused: Bool { isPaused && isEngineRunning }

    public var canPauseOrResume: Bool { isEngineRunning && client != nil }

    /// Asks Espanso whether it is running and reads what its log says about pauses and Secure Input.
    public func refreshEngine() async {
        guard let client else {
            isEngineRunning = false
            settleEngineStatus()
            return
        }
        let running = await client.isRunning()
        readEngineLog()
        isSecureInputActive = isSecureInputOn()
        setEngineRunning(running)
    }

    /// Follows the log from where the last read stopped.
    func readEngineLog() {
        guard let engineLog else { return }
        let result = engineLog.events(since: logPosition)
        logPosition = result.position
        for event in result.events {
            switch event {
            case .paused: isPaused = true
            case .resumed, .workerStarted: isPaused = false
            case .secureInputAcquired(let holder): secureInputHolder = holder
            case .secureInputReleased: secureInputHolder = nil
            }
        }
    }

    func setEngineRunning(_ running: Bool) {
        isEngineRunning = running
        // A service that stopped comes back with expansions on.
        if !running { isPaused = false }
        settleEngineStatus()
    }

    private func settleEngineStatus() {
        let status: EngineStatus
        if client == nil {
            status = .notInstalled
        } else if !isEngineRunning {
            status = .notRunning
        } else if isSecureInputActive {
            status = .secureInput
        } else if isPaused {
            status = .paused
        } else {
            status = .running
        }
        if !isSecureInputActive, secureInputHolder != nil { secureInputHolder = nil }
        if engineStatus != status { engineStatus = status }
    }

    /// Keeps the status up to date while the app runs. Called once by the app, not by tests.
    public func followEngine(every interval: Duration = .seconds(3)) {
        guard engineTask == nil else { return }
        engineTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.hasLoaded { await self.refreshEngine() }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    // MARK: Commands

    public func pauseExpansions() async {
        await sendToEngine { try await $0.pause() } then: { $0.isPaused = true }
    }

    public func resumeExpansions() async {
        await sendToEngine { try await $0.resume() } then: { $0.isPaused = false }
    }

    public func restartEngine() async {
        await sendToEngine { try await $0.restart() } then: { $0.isPaused = false }
    }

    public func startEngine() async {
        await sendToEngine { try await $0.start() } then: { $0.isPaused = false }
    }

    private func sendToEngine(
        _ command: (EspansoClient) async throws -> Void, then update: (AppModel) -> Void
    ) async {
        guard let client else {
            engineMessage = "Espanso wasn't found on this Mac."
            return
        }
        do {
            try await command(client)
            engineMessage = nil
            update(self)
            // The log line for the change may arrive after this; it says the same thing.
            await refreshEngine()
        } catch {
            engineMessage = Self.message(for: error)
            await refreshEngine()
        }
    }

    /// A sentence for a failed `espanso` command.
    static func message(for error: any Error) -> String {
        switch error as? CommandError {
        case .failed(_, let message)?:
            let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "Espanso reported an error." : "Espanso: \(line)"
        case .timedOut?:
            return "Espanso didn't answer in time."
        case .launchFailed?:
            return "The espanso program couldn't be started."
        default:
            return "Espanso reported an error."
        }
    }

    // MARK: Windows

    /// Brings the app forward and shows the main window.
    public func showMainWindow() {
        NSApp?.activate(ignoringOtherApps: true)
        openWindow?("main")
    }

    /// Shows an item in the main window's editor.
    public func reveal(_ id: Snippet.ID) {
        guard let set = set(containing: id) else { return }
        commitDraft()
        if !searchText.isEmpty { searchText = "" }
        selectedSetID = set.id
        selectedSnippetID = id
        showMainWindow()
    }
}
