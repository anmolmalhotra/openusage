//
//  PiUsageAggregationTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import XCTest
@testable import OpenUsage

final class PiUsageAggregationTests: XCTestCase {
    func testUntrustedCrossMessageTotalsCannotOverflow() throws {
        let data = Data(#"{"type":"message","timestamp":"2026-10-01T12:00:00Z","message":{"role":"assistant","provider":"xai","model":"grok","usage":{"input":4000000000000000000,"cost":{"total":1}}}}"#.utf8)
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(data))
        let scan = PiUsageScanner.aggregate(entries: [entry, entry, entry], cardID: "grok", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 8_000_000_000_000_000_000)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 2)
    }
    
    func testCostOverflowCannotPublishNonFiniteHistory() throws {
        let data = Data(#"{"type":"message","timestamp":"2026-10-01T12:00:00Z","message":{"role":"assistant","provider":"xai","model":"grok","usage":{"input":1,"cost":{"total":1e308}}}}"#.utf8)
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(data))
        let scan = PiUsageScanner.aggregate(entries: [entry, entry], cardID: "grok", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 1e308)
    }
    
    func testMissingModelWithTokensIsReportedAsUnpriced() throws {
        let data = Data(#"{"type":"message","timestamp":"2026-10-01T12:00:00Z","message":{"role":"assistant","provider":"xai","usage":{"input":1}}}"#.utf8)
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(data))
        let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "grok", since: .distantPast, pricing: .empty)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay.values.first, [ModelUsageEntry.unattributedModelName])
    }
}
