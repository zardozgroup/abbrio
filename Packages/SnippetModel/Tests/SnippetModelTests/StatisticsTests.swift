import XCTest
@testable import SnippetModel

final class StatisticsTests: XCTestCase {
    private func snippet(
        _ index: Int, file: String, _ triggers: [String], _ expansion: Expansion,
        regex: String? = nil, propagateCase: Bool = false
    ) -> Snippet {
        var snippet = Snippet(id: .init(file: file, index: index), triggers: triggers, regex: regex, expansion: expansion)
        snippet.options.propagateCase = propagateCase
        return snippet
    }

    private func set(_ name: String, _ snippets: [Snippet], enabled: Bool = true, countAs: CountAs = .expansions) -> SnippetSet {
        var set = SnippetSet(
            id: name.lowercased() + ".yml", name: name, kind: .abbreviations, isEnabled: enabled,
            files: [SetFile(path: "match/\(name.lowercased()).yml", url: URL(fileURLWithPath: "/tmp/\(name).yml"))],
            snippets: snippets
        )
        set.info.countAs = countAs
        return set
    }

    private var sets: [SnippetSet] {
        [
            set("Work", [
                snippet(0, file: "match/work.yml", ["btw"], .text("by the way"), propagateCase: true),
                snippet(1, file: "match/work.yml", [";sig", ";signature"], .text("Kind regards,\n$|$Sam")),
                snippet(2, file: "match/work.yml", [";logo"], .image(path: "/tmp/logo.png")),
                snippet(3, file: "match/work.yml", [], .text("$ {{n}}"), regex: "=(?P<n>\\d+)usd"),
            ]),
            set("AutoCorrect", [snippet(0, file: "match/autocorrect.yml", ["teh"], .text("the"))], countAs: .corrections),
            set("Old", [snippet(0, file: "match/old.yml", ["btw"], .text("BY THE WAY"))], enabled: false),
        ]
    }

    func testPeriodsStartWhereEspansoHasThemExceptToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_794_700_000) // 2026-11-14 in Los Angeles
        let midnight = StatisticsPeriod.today.start(now: now, calendar: calendar)!
        XCTAssertEqual(calendar.component(.hour, from: midnight), 0)
        XCTAssertTrue(calendar.isDate(midnight, inSameDayAs: now))
        XCTAssertEqual(StatisticsPeriod.week.start(now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(StatisticsPeriod.month.start(now: now), now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(StatisticsPeriod.year.start(now: now), now.addingTimeInterval(-365 * 86_400))
        XCTAssertNil(StatisticsPeriod.all.start(now: now))
        XCTAssertEqual(StatisticsPeriod.allCases.map(\.engineName), ["today", "week", "month", "year", "all"])
    }

    func testTypedTextIsMappedBackToItsItem() {
        let attribution = UsageAttribution(sets: sets)
        // The set that is switched on wins over the one that is off.
        XCTAssertEqual(attribution.target(for: "btw")?.setName, "Work")
        // Case variants belong to the item whose expansion follows the case.
        XCTAssertEqual(attribution.target(for: "Btw")?.snippet.id.index, 0)
        XCTAssertEqual(attribution.target(for: "BTW")?.setName, "Work")
        // Without that option, another case is another text.
        XCTAssertNil(attribution.target(for: "TEH"))
        XCTAssertEqual(attribution.target(for: ";signature")?.snippet.id.index, 1)
        // A regular expression is found by matching the whole recorded text.
        XCTAssertEqual(attribution.target(for: "=25usd")?.snippet.id.index, 3)
        XCTAssertNil(attribution.target(for: "x=25usd"))
        XCTAssertNil(attribution.target(for: ";gone"))
    }

    func testReportFoldsVariantsAndSplitsExpansionsFromCorrections() {
        let counts = [
            UsageCount(typed: "teh", count: 14), UsageCount(typed: "btw", count: 9), UsageCount(typed: "Btw", count: 2),
            UsageCount(typed: "BTW", count: 1), UsageCount(typed: ";sig", count: 7), UsageCount(typed: ";signature", count: 1),
            UsageCount(typed: "=25usd", count: 2), UsageCount(typed: "=7usd", count: 1), UsageCount(typed: ";logo", count: 3),
            UsageCount(typed: ";gone", count: 4), UsageCount(typed: "never", count: 0),
        ]
        let report = UsageReport(counts: counts, attribution: UsageAttribution(sets: sets))
        XCTAssertEqual(report.rows.map(\.trigger), ["teh", "btw", ";sig", ";gone", ";logo", "=(?P<n>\\d+)usd"])
        XCTAssertEqual(report.rows.map(\.count), [14, 12, 8, 4, 3, 3])
        XCTAssertEqual(report.rows.map(\.setName), ["AutoCorrect", "Work", "Work", nil, "Work", "Work"])
        XCTAssertEqual(report.total, 44)
        XCTAssertEqual(report.corrections, 14)
        XCTAssertEqual(report.expansions, 26)
        XCTAssertEqual(report.unattributed, 4)
        XCTAssertEqual(report.share(of: report.rows[0]), 14.0 / 44.0, accuracy: 0.0001)

        // teh -> the saves nothing; btw -> "by the way" saves 7 a time; the signature is 17 characters
        // without the cursor marker, typed as 4 (seven times) or 10 (once); "$ {{n}}" is 7 long against
        // 6 and 5 typed; a picture saves nothing.
        XCTAssertEqual(report.rows[1].charactersSaved, 12 * 7)
        XCTAssertEqual(report.rows[2].charactersSaved, 7 * 13 + 7)
        XCTAssertEqual(report.rows[5].charactersSaved, 2 * 1 + 2)
        XCTAssertEqual(report.charactersSaved, 84 + 98 + 4)
        XCTAssertEqual(report.minutesSaved(wordsPerMinute: 40), 186.0 / 200.0, accuracy: 0.0001)

        let top = report.top(2)
        XCTAssertEqual(top.rows.count, 2)
        XCTAssertEqual(top.otherTriggers, 4)
        XCTAssertEqual(top.otherCount, 18)
    }

    func testAnEmptyReport() {
        let report = UsageReport.empty
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(report.minutesSaved(wordsPerMinute: 40), 0)
        XCTAssertEqual(report.top(10).otherTriggers, 0)
    }

    func testRecentsFromEspansoMergeWithTheAppsOwn() {
        let attribution = UsageAttribution(sets: sets)
        let base = Date(timeIntervalSince1970: 1_794_700_000)
        let fromEspanso = attribution.recentUses(from: [
            UsageMoment(typed: "Btw", date: base.addingTimeInterval(-10)),
            UsageMoment(typed: ";gone", date: base.addingTimeInterval(-20)),
            UsageMoment(typed: ";signature", date: base.addingTimeInterval(-30)),
            UsageMoment(typed: "=25usd", date: base.addingTimeInterval(-40)),
        ])
        // Each is recorded under its item's first trigger; a regular expression has none and is left out.
        XCTAssertEqual(fromEspanso.map(\.trigger), ["btw", ";sig"])
        let own = [
            RecentUse(file: "match/work.yml", trigger: ";sig", date: base.addingTimeInterval(-5)),
            RecentUse(file: "match/autocorrect.yml", trigger: "teh", date: base.addingTimeInterval(-60)),
        ]
        let merged = RecentUse.merged(own, fromEspanso)
        XCTAssertEqual(merged.map(\.trigger), [";sig", "btw", "teh"])
        XCTAssertEqual(merged[0].date, base.addingTimeInterval(-5))
        XCTAssertEqual(RecentUse.merged(own, fromEspanso, limit: 1).count, 1)
    }
}
