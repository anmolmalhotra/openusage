//
//  PiNativeProviderTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import XCTest
@testable import OpenUsage

/// Pi history survives unavailable native credentials and combines with native hosted usage.
@MainActor
final class PiNativeProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    
    private func scanner(provider: String?) throws -> PiUsageScanner {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if let provider {
            let line = """
            {"type":"message","id":"pi-turn","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"\(provider)","model":"fixture-model","usage":{"input":100,"output":50,"totalTokens":150,"cost":{"total":0.5}}}}
            """
            try Data(line.utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        }
        return PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": directory.path]),
            homeDirectory: { directory },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
    }
    
    func testGrokPiHistoryAvailableWithoutNativeLogin() async throws {
        let now = now
        let runtime = GrokProvider(
            authStore: GrokAuthStore(files: FakeFiles()),
            logUsageScanner: GrokLogFixture.scanner(home: nil),
            piUsageScanner: try scanner(provider: "xai"),
            now: { now }, pricing: { .empty }
        )
        let detected = await runtime.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.5)
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }
    
    func testAntigravityPiHistoryAvailableWithoutNativeLogin() async throws {
        let now = now
        let runtime = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectories: { [] }),
            piUsageScanner: try scanner(provider: "google-antigravity"),
            now: { now }, pricing: { .empty }
        )
        let detected = await runtime.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 150)
    }
    
    func testGrokQuotaFailureKeepsNativeAndPiHistory() async throws {
        let now = now
        let home = try GrokLogFixture.makeHome(files: [
            "project/session/updates.jsonl": GrokLogFixture.completedTurn(
                timestamp: "2026-07-12T11:00:00.000Z", model: "grok-fixture",
                input: 1000, costUsdTicks: 1_000_000
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","expires_at":"2099-01-01T00:00:00.000Z"}}"#
        ])
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
        let runtime = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogFixture.scanner(home: home),
            piUsageScanner: try scanner(provider: "xai"),
            now: { now }, pricing: { .empty }
        )
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.reduce(0) { $0 + $1.totalTokens }, 1150)
        XCTAssertEqual(snapshot.lines.filter { $0.label == "Today" }.count, 1)
    }
    
    func testAntigravityAuthFailureKeepsNativeAndPiHistory() async throws {
        let now = now
        let fixture = try makeAntigravityDatabaseDirectory(for: self)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: antigravityGenerationBlob(
                model: "gemini-3.6-flash", input: 1000, output: 0,
                timestamp: UInt64(now.timeIntervalSince1970) - 3600
            ))
        ]])
        let runtime = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(
                sqlite: sqlite, conversationsDirectories: { [fixture.url.path] }
            ),
            piUsageScanner: try scanner(provider: "google-antigravity"),
            now: { now }, pricing: { antigravityPricing }
        )
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.reduce(0) { $0 + $1.totalTokens }, 1150)
        XCTAssertEqual(snapshot.lines.filter { $0.label == "Today" }.count, 1)
    }
    
    func testOpenCodeCombinesNativeAndPiHistoryOnce() async throws {
        let now = now
        let database = "[" + openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 1000, "native-model", "opencode") + "]"
        let runtime = OpenCodeProvider(
            authStore: openCodeAuthStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": database]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            piUsageScanner: try scanner(provider: "opencode-zen"),
            now: { now }, pricing: { .empty }
        )
        for _ in 0..<2 {
            let snapshot = await runtime.refresh()
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 2.5)
            XCTAssertEqual(snapshot.lines.filter { $0.label == "Today" }.count, 1)
            XCTAssertEqual(snapshot.lines.filter { $0.label == "Usage Trend" }.count, 1)
        }
    }
    
    func testOpenCodePiOnlyDetectionAndHistory() async throws {
        let now = now
        let runtime = OpenCodeProvider(
            authStore: openCodeAuthStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(databasePaths: { [] }),
            piUsageScanner: try scanner(provider: "opencode-go"),
            now: { now }, pricing: { .empty }
        )
        let detected = await runtime.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.5)
    }
    
    func testUnrelatedPiUsageDoesNotMaskMissingNativeLogin() async throws {
        let now = now
        let runtime = OpenCodeProvider(
            authStore: openCodeAuthStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(databasePaths: { [] }),
            piUsageScanner: try scanner(provider: "anthropic"),
            now: { now }, pricing: { .empty }
        )
        let detected = await runtime.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await runtime.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.warning)
    }
}
