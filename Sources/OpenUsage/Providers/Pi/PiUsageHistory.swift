//
//  PiUsageHistory.swift
//  OpenUsage
//
//  Created by Anmol Malhotra on 03/10/26.
//

import Foundation

/// Adds Pi's local sessions to a card whose native history is also machine-local. Account-wide
/// sources (Cursor and OpenRouter) already include requests made through Pi and must not use this.
enum PiUsageHistory {
    static func appending(_ piScan: LogUsageScan?,
                          to snapshot: ProviderSnapshot,
                          sourceNote: String,
                          now: Date) -> ProviderSnapshot {
        guard !Task.isCancelled, let piScan else { return snapshot }
        let hasUsage = piScan.series.daily.contains { $0.totalTokens > 0 || ($0.costUSD ?? 0) > 0 }
        if !hasUsage, piScan.unknownModelsByDay.isEmpty {
            // A completed empty scan clears previously cached Pi usage. A nil scan means the
            // source was unavailable; the data store may retain its last successful history.
            var result = snapshot
            if result.errorCategory == nil, result.usageHistory == nil {
                result.usageHistory = ProviderUsageHistory(series: piScan.series)
            }
            return result
        }
        let native = snapshot.usageHistory.map {
            LogUsageScan(series: $0.series,
                         modelUsage: $0.modelUsage,
                         unknownModelsByDay: $0.unknownModelsByDay,
                         fallbackPricingModelsByDay: $0.fallbackPricingModelsByDay)
        }
        guard let combined = DailyUsageAccumulator.merged([native, piScan]) else { return snapshot }
        let history = ProviderUsageHistory(series: combined.series,
                                           modelUsage: combined.modelUsage,
                                           unknownModelsByDay: combined.unknownModelsByDay,
                                           fallbackPricingModelsByDay: combined.fallbackPricingModelsByDay)
        var result = snapshot
        if case .badge(_, let message, _, _) = result.lines.first(where: \.isError) {
            AppLog.warn(LogTag.plugin(snapshot.providerID), "Live usage unavailable; showing local history: \(message)")
            result.warning = message
            result.errorCategory = nil
            result.lines.removeAll(where: \.isError)
        }
        result.lines.removeAll { $0 == .noUsageData }
        result.refreshedAt = now
        result.usageHistory = history
        result = UsageHistorySnapshotRenderer.render(local: result,
                                                     history: history,
                                                     descriptor: UsageHistoryDescriptor(scope: .machineLocal,
                                                                                        estimatedCost: true,
                                                                                        sourceNote: sourceNote),
                                                     now: now,
                                                     combined: false)
        MetricLine.appendNoDataIfNeeded(&result.lines)
        return result
    }
}
