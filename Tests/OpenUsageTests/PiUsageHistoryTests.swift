//
//  PiUsageHistoryTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import XCTest
@testable import OpenUsage

@MainActor
final class PiUsageHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)
    
    func testMergedHistoryPreservesMetersAndOnlyCountsEachSourceOnce() throws {
        let day = DailyUsageAccumulator.dayKey(from: now)
        var native = DailyUsageAccumulator()
        native.add(day: day, tokens: 10, cost: 1, model: "native")
        let nativeScan = native.build()
        let meter = MetricLine.progress(label: "Session", used: 25, limit: 100, format: .percent)
        let snapshot = ProviderSnapshot(providerID: "grok", displayName: "Grok", lines: [meter],
                                        usageHistory: ProviderUsageHistory(series: nativeScan.series,
                                                                           modelUsage: nativeScan.modelUsage))
        var pi = DailyUsageAccumulator()
        pi.add(day: day, tokens: 20, cost: 2, model: "pi")
        pi.addUnknownModel(day: day, model: "unknown")
        let result = PiUsageHistory.appending(pi.build(), to: snapshot, sourceNote: "Local sessions", now: now)
        XCTAssertEqual(result.line(label: "Session"), meter)
        XCTAssertEqual(result.usageHistory?.series.daily.first?.totalTokens, 30)
        XCTAssertEqual(result.usageHistory?.series.daily.first?.costUSD, 3)
        XCTAssertEqual(result.usageHistory?.unknownModelsByDay[day], ["unknown"])
        XCTAssertEqual(result.lines.filter { $0.label == "Today" }.count, 1)
        let total = TotalSpendAggregator.total(for: .today,
                                               providers: [Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))],
                                               snapshots: ["grok": result])
        XCTAssertEqual(total.totalUSD, 3)
        XCTAssertEqual(total.totalTokens, 30)
    }
    
    func testCompletedEmptyScanPublishesEmptyHistoryWithoutHidingLiveFailure() {
        let empty = DailyUsageAccumulator().build()
        let native = ProviderSnapshot(providerID: "copilot", displayName: "Copilot", lines: [])
        let result = PiUsageHistory.appending(empty, to: native, sourceNote: "Pi", now: now)
        // WidgetDataStore treats nil history as a scan miss and restores cached totals.
        XCTAssertEqual(result.usageHistory?.series.daily, [])
        let failed = ProviderSnapshot.error(provider: Provider(id: "copilot", displayName: "Copilot", icon: .providerMark("copilot")),
                                            error: CopilotAuthError.notLoggedIn)
        XCTAssertEqual(PiUsageHistory.appending(empty, to: failed, sourceNote: "Pi", now: now), failed)
        XCTAssertEqual(PiUsageHistory.appending(nil, to: native, sourceNote: "Pi", now: now), native)
    }
    
    func testUnpricedPiHistorySurvivesLiveFailureWithWarning() {
        let day = DailyUsageAccumulator.dayKey(from: now)
        var pi = DailyUsageAccumulator()
        pi.addUnknownModel(day: day, model: "unknown")
        let native = ProviderSnapshot.error(provider: Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai")),
                                            error: ZAIAuthError.missingKey)
        let result = PiUsageHistory.appending(pi.build(), to: native, sourceNote: "Pi", now: now)
        XCTAssertNotNil(result.warning)
        XCTAssertNil(result.errorCategory)
        XCTAssertFalse(result.lines.contains(where: \.isError))
        XCTAssertEqual(result.usageHistory?.unknownModelsByDay[day], ["unknown"])
    }
    
    func testNewMetricsAreDisabledUnpinnedAndOrderedAfterExistingMetrics() {
        let providers: [any ProviderRuntime] = [CopilotProvider(), OllamaProvider(), ZAIProvider()]
        for provider in providers {
            let prefix = provider.provider.id
            let ids = ["trend", "today", "yesterday", "last30"].map { "\(prefix).\($0)" }
            XCTAssertEqual(Array(provider.widgetDescriptors.suffix(4).map(\.id)), ids)
            for id in ids {
                XCTAssertFalse(DefaultLayout.metricIDs.contains(id))
                XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains(id))
                XCTAssertEqual(DefaultLayout.expandedMetricIDs.contains(id), !id.hasSuffix(".trend"))
            }
            XCTAssertEqual(provider.widgetDescriptors.compactMap(\.historyResource).map(\.scope), [.machineLocal])
        }
    }
}
