//
//  PiAdditionalUsageTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import Foundation
import XCTest
@testable import OpenUsage

final class PiAdditionalUsageTests: XCTestCase {
    func testTopLevelUsagePreservesAttributionAndUnknownKinds() throws {
        for kind in ["cache_warm", "future_operation"] {
            let data = try record(kind: kind)
            let entry = try XCTUnwrap(PiUsageScanner.parseLine(data, sessionID: "session"))
            XCTAssertEqual(entry.providerID, "anthropic")
            XCTAssertEqual(entry.cardID, "claude")
            XCTAssertEqual(entry.model, "claude-sonnet-4-5")
            XCTAssertEqual(entry.timestamp, OpenUsageISO8601.date(from: "2026-10-03T12:00:00Z"))
            XCTAssertEqual(entry.tokens.cacheRead, 50_000)
            XCTAssertEqual(entry.reportedTotalTokens, 50_000)
            XCTAssertEqual(entry.carriedCost, 0.015)
            XCTAssertEqual(entry.deduplicationKey, "pi:7:session:usage-id")
            let scan = PiUsageScanner.aggregate(
                entries: [entry], cardID: "claude", since: .distantPast, pricing: .empty
            )
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 50_000)
            XCTAssertEqual(scan.series.daily.first?.costUSD, 0.015)
        }
    }
    
    func testTopLevelUsageSharesSessionAndForkDeduplication() throws {
        let usage = try record()
        let original = try parsedSession("original", path: "/pi/original.jsonl", records: [usage, usage])
        let fork = try parsedSession("fork", path: "/pi/fork.jsonl", parent: "/pi/original.jsonl", records: [usage])
        let unrelated = try parsedSession("other", path: "/pi/other.jsonl", records: [usage])
        XCTAssertEqual(PiUsageScanner.dedup(original + fork + unrelated).count, 2)
    }
    
    func testTopLevelUsageRejectsUnknownProvidersAndInvalidTimestamps() throws {
        XCTAssertNil(PiUsageScanner.parseLine(try record(provider: "not-an-openusage-provider")))
        XCTAssertNil(PiUsageScanner.parseLine(try record(timestamp: "invalid")))
        let otherProvider = try XCTUnwrap(PiUsageScanner.parseLine(record(provider: "openai", model: "gpt-5")))
        XCTAssertEqual(otherProvider.cardID, "codex")
        XCTAssertEqual(otherProvider.model, "gpt-5")
    }
    
    func testUnattributedSummariesNeverBorrowPreviousProviderAndWarnOncePerFile() throws {
        let selection = Data(#"{"type":"model_change","id":"selection","provider":"anthropic","modelId":"claude-sonnet-4-5"}"#.utf8)
        var state = PiUsageScanner.ParseState(sourcePath: "/pi/session.jsonl")
        XCTAssertTrue(PiUsageScanner.parseFile(selection, state: &state).isEmpty)
        for type in ["compaction", "branch_summary"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: record()) as? [String: Any])
            object["type"] = type
            object["provider"] = nil
            object["model"] = nil
            object["summary"] = "Summary"
            object["fromHook"] = false
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertNil(PiUsageScanner.parseLine(data))
            XCTAssertTrue(PiUsageScanner.parseFile(data, state: &state).isEmpty)
            XCTAssertTrue(state.warnedUnattributedSummary)
        }
        let explicitUsage = PiUsageScanner.parseFile(try record(provider: "openai", model: "gpt-5"), state: &state)
        XCTAssertEqual(explicitUsage.first?.cardID, "codex")
        var separateFile = PiUsageScanner.ParseState(sourcePath: "/pi/other.jsonl")
        XCTAssertFalse(separateFile.warnedUnattributedSummary)
        XCTAssertEqual(PiUsageScanner.parseFile(try record(), state: &separateFile).count, 1)
        XCTAssertFalse(separateFile.warnedUnattributedSummary)
    }
    
    func testUsageProbeAndRefreshShareInclusiveWindow() async throws {
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-10-03T12:00:00Z"))
        let since = JSONLScanning.sinceDate(daysBack: 30, now: now)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiWindow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, testCase) in [(since.addingTimeInterval(-1), false), (since, true), (now, true), (now.addingTimeInterval(1), false)].enumerated() {
            let (timestamp, expected) = testCase
            let sessions = directory.appendingPathComponent("case-\(index)")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let file = sessions.appendingPathComponent("usage.jsonl")
            let text = ISO8601DateFormatter().string(from: timestamp)
            try record(timestamp: text).write(to: file)
            // Recent file metadata must not make an old/future message count as current usage.
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            let scanner = PiUsageScanner(
                environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": sessions.path]),
                homeDirectory: { directory }, incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
            )
            let detected = await scanner.hasUsage(cardID: "claude", now: now)
            let scan = await scanner.scan(cardID: "claude", now: now, pricing: .empty)
            XCTAssertEqual(detected, expected)
            XCTAssertEqual(scan?.series.daily.isEmpty, !expected)
            let wrongProvider = await scanner.hasUsage(cardID: "codex", now: now)
            XCTAssertFalse(wrongProvider)
        }
    }
    
    private func parsedSession(
        _ id: String, path: String, parent: String? = nil, records: [Data]
    ) throws -> [PiUsageScanner.Entry] {
        var header = ["type": "session", "id": id]
        header["parentSession"] = parent
        var data = try JSONSerialization.data(withJSONObject: header) + Data("\n".utf8)
        for record in records { data += record + Data("\n".utf8) }
        var state = PiUsageScanner.ParseState(sourcePath: path)
        return PiUsageScanner.parseFile(data, state: &state)
    }
    
    private func record(
        kind: String = "cache_warm", provider: String = "anthropic", model: String = "claude-sonnet-4-5",
        timestamp: String = "2026-10-03T12:00:00Z"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "usage", "id": "usage-id", "timestamp": timestamp,
            "kind": kind, "provider": provider, "model": model,
            "usage": ["input": 0, "output": 0, "cacheRead": 50_000, "cacheWrite": 0,
                      "totalTokens": 50_000, "cost": ["total": 0.015]]
        ])
    }
}
