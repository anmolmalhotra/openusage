//
//  PiUsageScannerRobustnessTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import Foundation
import XCTest
@testable import OpenUsage

final class PiUsageScannerRobustnessTests: XCTestCase {
    func testWhitespaceAndMissingTotalPreserveAllTokenBuckets() throws {
        let data = try message(usage: ["input": 10, "output": 3, "cacheRead": 2, "cacheWrite": 4])
        let spaced = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: ":", with: ": ").utf8)
        let entry = try XCTUnwrap(PiUsageScanner.parseFile(spaced).first)
        XCTAssertEqual(entry.reportedTotalTokens, 19)
        XCTAssertEqual(entry.providerID, "anthropic")
    }
    
    func testMalformedAndOutOfRangeTokenCountsNeverTrap() throws {
        let normalized = try XCTUnwrap(PiUsageScanner.parseLine(message(usage: [
            "input": -5, "output": true, "cacheRead": "not-a-number", "cacheWrite": 8,
            "cacheWrite1h": 20, "totalTokens": 0
        ])))
        XCTAssertEqual(normalized.tokens.input, 0)
        XCTAssertEqual(normalized.tokens.output, 0)
        XCTAssertEqual(normalized.tokens.cacheRead, 0)
        XCTAssertEqual(normalized.tokens.cacheWrite5m, 0)
        XCTAssertEqual(normalized.tokens.cacheWrite1h, 8)
        XCTAssertEqual(normalized.reportedTotalTokens, 8)
        XCTAssertNil(PiUsageScanner.parseLine(try message(usage: ["input": 1e30])))
        XCTAssertNil(PiUsageScanner.parseLine(try message(usage: ["input": 5e18, "output": 5e18])))
        XCTAssertNil(PiUsageScanner.parseLine(try message(usage: ["input": 0, "output": false])))
    }
    
    func testResponseModelAndPositiveCostFallbacks() throws {
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(message(
            model: "   ", responseModel: " claude-sonnet-4.5 ",
            usage: ["cost": ["total": 0.75]]
        )))
        XCTAssertEqual(entry.model, "claude-sonnet-4.5")
        XCTAssertEqual(entry.carriedCost, 0.75)
        let negative = try XCTUnwrap(PiUsageScanner.parseLine(message(usage: ["input": 1, "cost": ["total": -1]])))
        XCTAssertNil(negative.carriedCost)
    }
    
    func testSessionLocalIDsDeduplicateCopiesWithoutLosingOtherSessions() throws {
        let usage = try message()
        let first = PiUsageScanner.parseFile(try session("first") + usage + Data("\n".utf8) + usage)
        let copied = PiUsageScanner.parseFile(try session("first") + usage)
        let other = PiUsageScanner.parseFile(try session("other") + usage)
        XCTAssertEqual(PiUsageScanner.dedup(first + copied + other).count, 2)
        let headerless = PiUsageScanner.parseFile(usage + Data("\n".utf8) + usage)
        XCTAssertEqual(PiUsageScanner.dedup(headerless).count, 2)
        XCTAssertNil(headerless.first?.deduplicationKey)
    }
    
    func testExplicitSessionIdentityOverridesHeader() throws {
        let a = try message(sessionID: "session-a")
        let b = try message(sessionID: "session-b")
        let entries = PiUsageScanner.parseFile(try session("header") + a + Data("\n".utf8) + b)
        XCTAssertEqual(PiUsageScanner.dedup(entries).count, 2)
        XCTAssertEqual(entries.first?.deduplicationKey, "pi:9:session-a:short-id")
    }
    
    func testRealForkPreservesNewRequestsAndDeduplicatesInheritedUsage() throws {
        let inherited = try message()
        let next = try message(id: "new-request")
        let original = try parsedSession("original", path: "/pi/original.jsonl", messages: [inherited])
        let fork = try parsedSession(
            "fork", path: "/pi/fork.jsonl", parent: "/pi/original.jsonl", messages: [inherited, next]
        )
        XCTAssertEqual(PiUsageScanner.dedup(original + fork).count, 2)
        XCTAssertEqual(PiUsageScanner.dedup(fork + original).count, 2)
        let scan = PiUsageScanner.aggregate(
            entries: PiUsageScanner.dedup(original + fork), cardID: "claude", since: .distantPast, pricing: .empty
        )
        XCTAssertEqual(scan.series.daily.first?.costUSD, 1)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 26)
    }
    
    func testUnrelatedIdenticalRequestsAndDistinctBranchRequestsSurvive() throws {
        let same = try message()
        let original = try parsedSession("a", path: "/pi/a.jsonl", messages: [same])
        let unrelated = try parsedSession("b", path: "/pi/b.jsonl", messages: [same])
        let changed = try message(usage: ["input": 20, "output": 3, "cost": ["total": 0.75]])
        let fork = try parsedSession("c", path: "/pi/c.jsonl", parent: "/pi/a.jsonl", messages: [changed])
        XCTAssertEqual(PiUsageScanner.dedup(original + unrelated + fork).count, 3)
    }
    
    func testCopiesAndMultipleForkGenerationsShareLineage() throws {
        let a = try message(id: "a")
        let b = try message(id: "b")
        let c = try message(id: "c")
        let original = try parsedSession("root", path: "/pi/root.jsonl", messages: [a])
        let copy = try parsedSession("root", path: "/pi/copied.jsonl", messages: [a])
        let first = try parsedSession("first", path: "/pi/first.jsonl", parent: "/pi/copied.jsonl", messages: [a, b])
        let second = try parsedSession("second", path: "/pi/second.jsonl", parent: "/pi/first.jsonl", messages: [a, b, c])
        XCTAssertEqual(PiUsageScanner.dedup(second + copy + first + original).count, 3)
    }
    
    func testMissingParentStillConnectsForkSiblingsAndCyclesTerminate() throws {
        let inherited = try message()
        let first = try parsedSession("first", path: "/pi/first.jsonl", parent: "/pi/missing.jsonl", messages: [inherited])
        let second = try parsedSession("second", path: "/pi/second.jsonl", parent: "/pi/missing.jsonl", messages: [inherited])
        XCTAssertEqual(PiUsageScanner.dedup(first + second).count, 1)
        let cycleA = try parsedSession("a", path: "/pi/a.jsonl", parent: "/pi/b.jsonl", messages: [inherited])
        let cycleB = try parsedSession("b", path: "/pi/b.jsonl", parent: "/pi/a.jsonl", messages: [inherited])
        XCTAssertEqual(PiUsageScanner.dedup(cycleA + cycleB).count, 1)
    }
    
    func testHeaderlessFilesDeduplicateWithinTheirOwnPaths() throws {
        let message = try message()
        var firstState = PiUsageScanner.ParseState(sourcePath: "/pi/first.jsonl")
        var secondState = PiUsageScanner.ParseState(sourcePath: "/pi/second.jsonl")
        let first = PiUsageScanner.parseFile(message + Data("\n".utf8) + message, state: &firstState)
        let second = PiUsageScanner.parseFile(message, state: &secondState)
        XCTAssertEqual(PiUsageScanner.dedup(first + second).count, 2)
    }
    
    func testAggregationExcludesFutureMessages() throws {
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(message()))
        let scan = PiUsageScanner.aggregate(
            entries: [entry], cardID: "claude", since: .distantPast, pricing: .empty,
            until: entry.timestamp.addingTimeInterval(-1)
        )
        XCTAssertTrue(scan.series.daily.isEmpty)
    }
    
    func testLocalUsageProbeUsesMappedTranscripts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = try message()
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "2026-10-03", with: "2020-01-01").utf8)
        try data.write(to: directory.appendingPathComponent("session.jsonl"))
        let scanner = PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": directory.path]),
            homeDirectory: { directory }, incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2020-01-02T12:00:00Z"))
        let hasClaude = await scanner.hasUsage(cardID: "claude", now: now)
        let hasCodex = await scanner.hasUsage(cardID: "codex", now: now)
        XCTAssertTrue(hasClaude)
        XCTAssertFalse(hasCodex)
    }
    
    func testStreamingHeaderIdentitySurvivesBatchesCacheAndAppend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiScanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("session.jsonl")
        // Enough non-usage records to put the response in a later bounded reader batch.
        let padding = Data(String(repeating: "{\"type\":\"custom\",\"data\":\"padding\"}\n", count: 3_000).utf8)
        let parentPath = directory.appendingPathComponent("parent.jsonl").resolvingSymlinksInPath().path
        let data = try session("streamed", parent: parentPath) + padding + message() + Data("\n".utf8)
        try data.write(to: fileURL)
        let persistence = JSONLScanCachePersistence(
            namespace: "pi-test", schemaVersion: 3,
            directory: directory.appendingPathComponent("cache"), writeDebounce: .milliseconds(1)
        )
        let firstCache = IncrementalJSONLScanner<PiUsageScanner.Entry>(persistence: persistence)
        let files = JSONLScanning.jsonlFiles(under: directory)
        let cold = await firstCache.items(
            from: files, since: .distantPast, initialState: PiUsageScanner.ParseState(),
            initialStateForFile: { PiUsageScanner.ParseState(sourcePath: $0) },
            parse: PiUsageScanner.parseFile
        )
        XCTAssertEqual(cold?.first?.deduplicationKey, "pi:8:streamed:short-id")
        XCTAssertEqual(cold?.first?.sourcePath, fileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(cold?.first?.sessionID, "streamed")
        XCTAssertEqual(cold?.first?.parentPath, parentPath)
        await firstCache.flushPendingWrites()
        let reloaded = IncrementalJSONLScanner<PiUsageScanner.Entry>(persistence: persistence)
        let warm = await reloaded.items(
            from: files, since: .distantPast, initialState: PiUsageScanner.ParseState(),
            initialStateForFile: { PiUsageScanner.ParseState(sourcePath: $0) },
            parse: PiUsageScanner.parseFile
        )
        XCTAssertEqual(warm, cold)
        try (data + message(id: "second-id") + Data("\n".utf8)).write(to: fileURL)
        let appended = await reloaded.items(
            from: JSONLScanning.jsonlFiles(under: directory), since: .distantPast,
            initialState: PiUsageScanner.ParseState(),
            initialStateForFile: { PiUsageScanner.ParseState(sourcePath: $0) }, parse: PiUsageScanner.parseFile
        )
        XCTAssertEqual(appended?.count, 2)
        XCTAssertEqual(appended?.last?.deduplicationKey, "pi:8:streamed:second-id")
        await reloaded.flushPendingWrites()
    }
    
    private func session(_ id: String, parent: String? = nil) throws -> Data {
        var header = ["type": "session", "id": id]
        header["parentSession"] = parent
        return try JSONSerialization.data(withJSONObject: header) + Data("\n".utf8)
    }
    
    private func parsedSession(
        _ id: String, path: String, parent: String? = nil, messages: [Data]
    ) throws -> [PiUsageScanner.Entry] {
        var state = PiUsageScanner.ParseState(sourcePath: path)
        var data = try session(id, parent: parent)
        for message in messages { data += message + Data("\n".utf8) }
        return PiUsageScanner.parseFile(data, state: &state)
    }
    
    private func message(
        id: String = "short-id", sessionID: String? = nil,
        model: String = "claude-sonnet-4.5", responseModel: String? = nil,
        usage: [String: Any] = ["input": 10, "output": 3, "cost": ["total": 0.5]]
    ) throws -> Data {
        var message: [String: Any] = [
            "role": "assistant", "provider": "anthropic", "model": model, "usage": usage
        ]
        message["responseModel"] = responseModel
        var record: [String: Any] = [
            "type": "message", "id": id, "timestamp": "2026-10-03T12:00:00Z", "message": message
        ]
        record["session_id"] = sessionID
        return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }
}
