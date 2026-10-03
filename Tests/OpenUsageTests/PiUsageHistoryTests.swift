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
        XCTAssertTrue(result.warning?.contains(ZAIAuthError.missingKey.localizedDescription) == true)
        XCTAssertTrue(result.warning?.contains("Usage totals are unavailable for unknown models: unknown.") == true)
        XCTAssertNil(result.errorCategory)
        XCTAssertFalse(result.lines.contains(where: \.isError))
        XCTAssertEqual(result.usageHistory?.unknownModelsByDay[day], ["unknown"])
    }
    
    func testUnknownOnlyHistoryWarnsWithAndWithoutNativeMeters() {
        let day = DailyUsageAccumulator.dayKey(from: now)
        var pi = DailyUsageAccumulator()
        pi.addUnknownModel(day: day, model: "unknown-b")
        pi.addUnknownModel(day: day, model: "unknown-a")
        let meter = MetricLine.progress(label: "Session", used: 25, limit: 100, format: .percent)
        for nativeLines in [[], [meter]] {
            let snapshot = ProviderSnapshot(providerID: "grok", displayName: "Grok", lines: nativeLines)
            let result = PiUsageHistory.appending(pi.build(), to: snapshot, sourceNote: "Pi", now: now)
            XCTAssertEqual(result.warning, "Usage totals are unavailable for unknown models: unknown-a, unknown-b.")
            XCTAssertEqual(result.line(label: "Session"), nativeLines.first)
            XCTAssertNil(result.line(label: "Today"), "Unknown usage must not fabricate zero totals")
        }
    }
    
    func testUnknownOnlyNoticeIsReplacedAndClearedWithoutLosingLiveWarning() {
        let day = DailyUsageAccumulator.dayKey(from: now)
        let descriptor = UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        let unknownHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: []),
                                                   unknownModelsByDay: [day: ["unknown"]])
        var snapshot = ProviderSnapshot(providerID: "grok", displayName: "Grok", lines: [],
                                        warning: "Live usage unavailable")
        for _ in 0..<2 {
            snapshot = UsageHistorySnapshotRenderer.render(local: snapshot, history: unknownHistory,
                                                             descriptor: descriptor, now: now)
            XCTAssertEqual(snapshot.warning,
                           "Live usage unavailable\nUsage totals are unavailable for unknown models: unknown.")
        }
        let updatedHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: []),
                                                   unknownModelsByDay: [day: ["new-model"]])
        snapshot = UsageHistorySnapshotRenderer.render(local: snapshot, history: updatedHistory,
                                                         descriptor: descriptor, now: now)
        XCTAssertEqual(snapshot.warning,
                       "Live usage unavailable\nUsage totals are unavailable for unknown models: new-model.")
        let removed = UsageHistorySnapshotRenderer.removingHistory(from: snapshot)
        XCTAssertEqual(removed.warning, "Live usage unavailable")
        var priced = DailyUsageAccumulator()
        priced.add(day: day, tokens: 20, cost: 1, model: "known")
        let rendered = UsageHistorySnapshotRenderer.render(
            local: snapshot, history: ProviderUsageHistory(series: priced.build().series),
            descriptor: descriptor, now: now
        )
        XCTAssertEqual(rendered.warning, "Live usage unavailable")
        XCTAssertNotNil(rendered.line(label: "Today"))
    }
    
    func testPricedUsageKeepsExistingPerRowUnknownModelWarning() {
        let day = DailyUsageAccumulator.dayKey(from: now)
        var pi = DailyUsageAccumulator()
        pi.add(day: day, tokens: 20, cost: 1, model: "known")
        pi.addUnknownModel(day: day, model: "unknown")
        let snapshot = ProviderSnapshot(providerID: "grok", displayName: "Grok", lines: [])
        let result = PiUsageHistory.appending(pi.build(), to: snapshot, sourceNote: "Pi", now: now)
        XCTAssertNil(result.warning)
        guard case .values(_, _, _, _, let models, _) = result.line(label: "Today") else {
            return XCTFail("Expected a spend row")
        }
        XCTAssertEqual(models, ["unknown"])
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
