import ConfigStore
import EspansoCLI
import Foundation
public import SnippetModel

/// Where the figures in the Statistics window came from.
public nonisolated enum StatisticsSource: Hashable, Sendable {
    /// Read from `stats.db`.
    case database
    /// From `espanso stats --json`, because the database could not be read.
    case command
}

// Espanso's usage counts, as the Statistics window shows them.
extension AppModel {
    /// Reads the counts for the chosen period again.
    public func refreshStatistics() async {
        guard let folder = configFolder else {
            usageReport = .empty
            statisticsNote = "No config folder."
            return
        }
        let period = statisticsPeriod
        let attribution = UsageAttribution(sets: sets)
        let database = StatsDatabase(configFolder: folder)
        let start = period.start(now: Date())

        var counts: [UsageCount] = []
        var source = StatisticsSource.database
        var note: String?
        switch await Self.readCounts(database, since: start) {
        case .success(let read):
            counts = read
        case .failure(.missing):
            note = statisticsAreOn
                ? "Nothing has been counted yet."
                : "Espanso has no statistics database yet. It is created once statistics are switched on."
        case .failure(let error):
            // The layout is not documented. When it isn't the one the app knows, Espanso is asked instead.
            source = .command
            do {
                guard let client else { throw CommandError.launchFailed("no espanso") }
                counts = try await client.stats(period: period)
                note = "The statistics database couldn\u{2019}t be read, so these figures come from espanso stats."
                    + (period == .today ? " Its Today starts at midnight UTC." : "")
            } catch {
                note = "The statistics could not be read."
            }
            if case .unreadable(let message) = error, counts.isEmpty { note = "The statistics could not be read: \(message)" }
        }
        // A newer request may have been made while this one waited.
        guard period == statisticsPeriod else { return }
        usageReport = UsageReport(counts: counts, attribution: attribution)
        statisticsSource = source
        statisticsNote = note
    }

    @concurrent
    private nonisolated static func readCounts(
        _ database: StatsDatabase, since start: Date?
    ) async -> Result<[UsageCount], StatsDatabaseError> {
        do throws(StatsDatabaseError) {
            return .success(try database.counts(since: start))
        } catch {
            return .failure(error)
        }
    }

    /// `espanso stats clear`
    public func clearStatistics() async {
        await changeStatistics { try await $0.clearStats() }
    }

    /// `espanso stats prune --days <n>`
    public func pruneStatistics(olderThanDays days: Int) async {
        await changeStatistics { try await $0.pruneStats(olderThanDays: days) }
    }

    private func changeStatistics(_ command: (EspansoClient) async throws -> Void) async {
        guard let client else {
            alertMessage = "Espanso wasn\u{2019}t found on this Mac."
            return
        }
        do {
            try await command(client)
        } catch {
            alertMessage = Self.message(for: error)
        }
        refreshEngineRecents()
        await refreshStatistics()
    }

    /// Reads what Espanso recorded last, for the Quick Search list of recent items.
    func refreshEngineRecents() {
        guard let folder = configFolder else {
            engineRecents = []
            return
        }
        let moments = (try? StatsDatabase(configFolder: folder).recents(limit: 100)) ?? []
        engineRecents = UsageAttribution(sets: sets).recentUses(from: moments)
    }

    /// The app's own Quick Search history together with what Espanso recorded, newest first.
    var quickSearchRecents: [RecentUse] {
        RecentUse.merged(recentUses, engineRecents)
    }
}
