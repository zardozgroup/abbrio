import AppKit
import SnippetModel
public import SwiftUI

/// The Statistics window: how often each abbreviation was used, from Espanso's own counts.
public struct StatisticsWindow: View {
    let model: AppModel

    @State private var showsAll = false
    @State private var pruneDays = 30
    @State private var isConfirmingClear = false
    @State private var isConfirmingPrune = false
    @State private var isWorking = false

    /// How many rows are listed before the rest are summed up in one line.
    static let rowLimit = 10

    public init(model: AppModel) {
        self.model = model
    }

    private var report: UsageReport { model.usageReport }

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                status
                if model.statisticsAreOn || report.total > 0 {
                    cards
                    table
                } else {
                    Spacer()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Period", selection: $model.statisticsPeriod) {
                    ForEach(StatisticsPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("The span of time the figures cover")
            }
        }
        .task(id: model.statisticsPeriod) {
            if !model.hasLoaded { await model.load() }
            showsAll = false
            await model.refreshStatistics()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshStatistics() }
        }
        .confirmationDialog("Clear all statistics?", isPresented: $isConfirmingClear) {
            Button("Clear Statistics", role: .destructive) { run { await model.clearStatistics() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Espanso deletes every count it has recorded. This can\u{2019}t be undone.")
        }
        .confirmationDialog("Delete counts older than \(pruneDays) days?", isPresented: $isConfirmingPrune) {
            Button("Prune", role: .destructive) { run { await model.pruneStatistics(olderThanDays: pruneDays) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Espanso deletes the records of expansions made more than \(pruneDays) days ago. This can\u{2019}t be undone.")
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }

    // MARK: Status line

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !model.supportsStatistics {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Statistics need Espanso 2.4.0 or later.")
                } else if model.statisticsAreOn {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Statistics are on")
                    Tag("stats: enabled: true", .yaml)
                    Text("in config/default.yml").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    Text("Statistics are off.")
                    Text("Espanso counts nothing until they are switched on.").foregroundStyle(.secondary)
                    Button("Turn On Statistics") { model.setStatistics(true) }
                        .disabled(!model.canChangeEngineOptions)
                }
                Spacer()
            }
            if let note = model.statisticsNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Summary cards

    private var cards: some View {
        HStack(spacing: 12) {
            StatCard(title: "Expansions", value: report.expansions.formatted(), note: "Sets counted as Expansions")
            StatCard(title: "Corrections", value: report.corrections.formatted(), note: "Sets counted as Corrections")
            StatCard(title: "Characters saved", value: report.charactersSaved.formatted(), note: "(expansion \u{2212} trigger length) \u{00D7} count")
            StatCard(
                title: "Time saved", value: Self.timeSaved(report.minutesSaved(wordsPerMinute: model.preferences.typingSpeed)),
                note: "Estimate at \(model.preferences.typingSpeed) wpm, set in Settings"
            )
        }
    }

    /// An estimate, so it is always marked as approximate.
    static func timeSaved(_ minutes: Double) -> String {
        if minutes <= 0 { return "\u{2248} 0 min" }
        if minutes < 1 { return "\u{2248} \(max(1, Int((minutes * 60).rounded()))) s" }
        if minutes < 90 { return "\u{2248} \(Int(minutes.rounded())) min" }
        return "\u{2248} \((minutes / 60).formatted(.number.precision(.fractionLength(1)))) h"
    }

    // MARK: Table

    private var table: some View {
        let top = showsAll ? (rows: report.rows, otherTriggers: 0, otherCount: 0) : report.top(Self.rowLimit)
        return VStack(spacing: 0) {
            StatRowLayout(
                trigger: Text("Trigger"), set: Text("Set"), countedAs: Text("Counted as"),
                count: Text("Count"), share: Text("Share").frame(maxWidth: .infinity, alignment: .leading)
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(top.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                    }
                    if top.otherTriggers > 0 {
                        others(count: top.otherCount, triggers: top.otherTriggers)
                    }
                    if report.rows.isEmpty {
                        Text(model.statisticsAreOn ? "Nothing was expanded in this period." : "Nothing has been counted.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 28)
                    }
                    if showsAll, report.rows.count > Self.rowLimit {
                        Button("Show Fewer") { showsAll = false }.buttonStyle(.link).padding(.vertical, 8)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rowView(_ row: UsageRow) -> some View {
        let share = report.share(of: row)
        return StatRowLayout(
            trigger: Text(row.trigger).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle),
            set: Text(row.setName ?? "Not in any set").foregroundStyle(row.setName == nil ? .secondary : .primary).lineLimit(1),
            countedAs: Text(Self.countedAs(row.countAs)).foregroundStyle(.secondary),
            count: Text(row.count.formatted()).monospacedDigit(),
            share: ShareBar(share: share, length: barLength(row.count), color: Self.color(row.countAs))
        )
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let id = row.snippetID { model.reveal(id) }
        }
        .help(row.snippetID == nil ? "Typed text that no item in your sets explains, such as an item deleted since" : "Double-click to show the item")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.trigger), \(row.setName ?? "not in any set"), \(row.count) times, \(Int((share * 100).rounded())) percent")
    }

    private func others(count: Int, triggers: Int) -> some View {
        StatRowLayout(
            trigger: Button(triggers == 1 ? "1 other trigger" : "\(triggers) other triggers") { showsAll = true }
                .buttonStyle(.link)
                .help("Show every trigger"),
            set: Text("\u{2014}").foregroundStyle(.secondary),
            countedAs: Text("Mixed").foregroundStyle(.secondary),
            count: Text(count.formatted()).monospacedDigit(),
            share: ShareBar(share: report.total == 0 ? 0 : Double(count) / Double(report.total), length: barLength(count), color: .gray)
        )
        .padding(.vertical, 6)
    }

    /// The bars are drawn against the largest row, so the most used trigger fills the column.
    private func barLength(_ count: Int) -> Double {
        let largest = max(report.rows.first?.count ?? 0, 1)
        return min(1, Double(count) / Double(largest))
    }

    static func countedAs(_ kind: CountAs?) -> String {
        switch kind {
        case .expansions?: return "Expansion"
        case .corrections?: return "Correction"
        case nil: return "\u{2014}"
        }
    }

    static func color(_ kind: CountAs?) -> Color {
        switch kind {
        case .expansions?: return .accentColor
        case .corrections?: return .orange
        case nil: return .gray
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.statisticsSource == .database ? "Read from stats.db in the config folder, read-only" : "From espanso stats")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Prune older than")
            TextField("Days", value: $pruneDays, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .accessibilityLabel("Days to keep")
            Text("days")
            Button("Prune") { isConfirmingPrune = true }
                .disabled(pruneDays < 1 || isWorking || model.engineStatus == .notInstalled)
            Divider().frame(height: 18)
            Button("Clear Statistics\u{2026}", role: .destructive) { isConfirmingClear = true }
                .foregroundStyle(.red)
                .disabled(isWorking || model.engineStatus == .notInstalled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// One summary card.
private struct StatCard: View {
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}

/// The five columns of the table, shared by the heading and the rows so they line up.
private struct StatRowLayout<Trigger: View, SetName: View, CountedAs: View, Count: View, Share: View>: View {
    let trigger: Trigger
    let set: SetName
    let countedAs: CountedAs
    let count: Count
    let share: Share

    var body: some View {
        HStack(spacing: 12) {
            trigger.frame(width: 190, alignment: .leading)
            set.frame(width: 150, alignment: .leading)
            countedAs.frame(width: 100, alignment: .leading)
            count.frame(width: 60, alignment: .trailing)
            share.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }
}

/// A bar for a row's share of all expansions, with the percentage after it.
private struct ShareBar: View {
    /// The row's part of all expansions, shown as the percentage.
    let share: Double
    /// How much of the column the bar fills, from 0 to 1.
    let length: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: max(length > 0 ? 3 : 0, proxy.size.width * length))
                }
            }
            .frame(height: 7)
            Text("\(Int((share * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

#if DEBUG
#Preview("Statistics") {
    @Previewable @State var model = WindowPreview.makeModel()
    StatisticsWindow(model: model)
        .frame(width: 1100, height: 740)
}
#endif
