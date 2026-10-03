//
//  PiQuotaProviderTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import XCTest
@testable import OpenUsage

/// Pi usage remains available on quota-provider cards without a native account, and never changes
/// the remote quota meters or leaks a different provider's local sessions into the card.
@MainActor
final class PiQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)
    
    func testLocalSessionsPopulateMatchingCardsWithoutNativeCredentials() async throws {
        let fixture = try makeScanner(providers: ["github-copilot", "ollama", "zai"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let instant = now
        let providers: [any ProviderRuntime] = [
            CopilotProvider(
                authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
                piUsageScanner: fixture.scanner, now: { instant }, pricing: { .empty }
            ),
            OllamaProvider(
                authStore: OllamaAuthStore(files: FakeFiles()),
                piUsageScanner: fixture.scanner, now: { instant }, pricing: { .empty }
            ),
            ZAIProvider(
                authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
                piUsageScanner: fixture.scanner, now: { instant }, pricing: { .empty }
            )
        ]
        for provider in providers {
            let detected = await provider.hasLocalCredentials()
            XCTAssertTrue(detected, provider.provider.id)
            let snapshot = await provider.refresh()
            XCTAssertNil(snapshot.errorCategory, provider.provider.id)
            XCTAssertNotNil(snapshot.warning, provider.provider.id)
            XCTAssertFalse(snapshot.lines.contains { $0.isError }, provider.provider.id)
            XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.5, provider.provider.id)
            XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 150, provider.provider.id)
        }
    }
    
    func testUnrelatedPiSessionsDoNotEnableOllamaOrClearNativeError() async throws {
        let fixture = try makeScanner(providers: ["anthropic"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let instant = now
        let provider = OllamaProvider(
            authStore: OllamaAuthStore(files: FakeFiles()),
            piUsageScanner: fixture.scanner, now: { instant }, pricing: { .empty }
        )
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }
    
    func testNativeQuotaLinesAndPlanSurvivePiFoldIn() async throws {
        let fixture = try makeScanner(providers: ["zai", "anthropic"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let instant = now
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "test-key"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                let body = request.url == ZAIUsageClient.quotaURL
                    ? #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]},"success":true}"#
                    : #"{"data":[{"productName":"GLM Coding Max"}]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }),
            piUsageScanner: fixture.scanner, now: { instant }, pricing: { .empty }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "GLM Coding Max")
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
        guard case .progress(_, let used, let limit, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("Missing native Session meter")
        }
        XCTAssertEqual(used, 25)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.5)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 150)
    }
    
    private func makeScanner(providers: [String]) throws -> (directory: URL, scanner: PiUsageScanner) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = OpenUsageISO8601.string(from: now.addingTimeInterval(-60))
        let records = providers.enumerated().map { index, provider in
            """
            {"type":"message","id":"message-\(index)","timestamp":"\(timestamp)","message":{"role":"assistant","provider":"\(provider)","model":"test-model","usage":{"input":100,"output":50,"totalTokens":150,"cost":{"total":0.5}}}}
            """
        }
        try records.joined(separator: "\n").write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let scanner = PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": directory.path]),
            homeDirectory: { directory }, incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
        return (directory, scanner)
    }
}
