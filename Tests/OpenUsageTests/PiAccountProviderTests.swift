//
//  PiAccountProviderTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class PiAccountProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-02-20T14:30:00Z")!
    
    func testOpenAIPiHistoryWorksWithoutCodexLogin() async throws {
        let directory = try fixture(provider: "openai")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = codex(directory: directory)
        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.25)
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }
    
    func testAccountSpecificCardUsesCanonicalCodexFamilyOnSuccessfulScan() async throws {
        let directory = try fixture(provider: "openai-codex")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = codex(directory: directory, cardID: "codex.account-fixture")
        let snapshot = await provider.snapshot(mapped: CodexMappedUsage(plan: "Pro", lines: []))
        XCTAssertEqual(snapshot.providerID, "codex.account-fixture")
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.25)
    }
    
    func testMultiAccountGuardExcludesUnattributedCodexPiUsage() async throws {
        let directory = try fixture(provider: "openai-codex")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = codex(directory: directory, allowed: false)
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let failed = await provider.refresh()
        XCTAssertNotNil(failed.errorCategory)
        XCTAssertNil(failed.usageHistory)
        let successful = await provider.snapshot(mapped: CodexMappedUsage(plan: "Pro", lines: []))
        XCTAssertNil(successful.usageHistory)
    }
    
    func testClaudePiOnlyHistoryUsesCanonicalFamilyAndHonorsAccountGuard() async throws {
        let directory = try fixture(provider: "anthropic")
        defer { try? FileManager.default.removeItem(at: directory) }
        for allowed in [true, false] {
            let provider = ClaudeProvider(
                provider: ClaudeProvider.makeProvider(id: "claude.account-fixture"),
                authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain()),
                logUsageScanner: ClaudeLogUsageScanner(
                    environment: FakeEnvironment(), homeDirectory: { directory },
                    incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
                ),
                piUsageScanner: scanner(directory), allowsUnattributedPiUsage: allowed,
                now: { [now] in now }, pricing: { .empty }
            )
            let detected = await provider.hasLocalCredentials()
            XCTAssertEqual(detected, allowed)
            let snapshot = await provider.refresh()
            if allowed {
                XCTAssertNil(snapshot.errorCategory)
                XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 15)
            } else {
                XCTAssertNotNil(snapshot.errorCategory)
                XCTAssertNil(snapshot.usageHistory)
            }
        }
    }
    
    func testClaudeLiveFailuresKeepPiHistoryWithoutLeakingAcrossAccounts() async throws {
        let directory = try fixture(provider: "anthropic")
        defer { try? FileManager.default.removeItem(at: directory) }
        for statusCode in [401, 503] {
            for allowed in [true, false] {
                let provider = ClaudeProvider(
                    authStore: ClaudeAuthStore(
                        environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": directory.path]),
                        files: FakeFiles([
                            directory.appendingPathComponent(".credentials.json").path:
                                #"{"claudeAiOauth":{"accessToken":"rejected-token","expiresAt":1,"scopes":["user:profile"]}}"#
                        ]),
                        keychain: FakeKeychain(), now: { [now] in now }
                    ),
                    usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(
                        statusCode: statusCode, headers: [:], body: Data()
                    ))),
                    logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                    piUsageScanner: scanner(directory), allowsUnattributedPiUsage: allowed,
                    now: { [now] in now }, pricing: { .empty }
                )
                let snapshot = await provider.refresh()
                if allowed {
                    XCTAssertNil(snapshot.errorCategory)
                    XCTAssertNotNil(snapshot.warning)
                    XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 15)
                    XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.25)
                    XCTAssertNotNil(snapshot.line(label: "Today"))
                } else {
                    XCTAssertNotNil(snapshot.errorCategory)
                    XCTAssertNil(snapshot.usageHistory)
                    XCTAssertNil(snapshot.line(label: "Today"))
                }
            }
        }
    }
    
    func testCodexOutagePreservesCombinedNativeAndPiHistory() async throws {
        let directory = try fixture(provider: "openai")
        let nativeHome = try CodexLogFixture.makeHome(files: [
            "sessions/rollout.jsonl": [
                CodexLogFixture.turnContext(timestamp: "2026-02-20T14:00:00Z", model: "gpt-5.2"),
                CodexLogFixture.tokenCount(timestamp: "2026-02-20T14:01:00Z",
                                           last: CodexLogFixture.usage(input: 100, output: 50))
            ].joined(separator: "\n")
        ])
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: nativeHome)
        }
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": nativeHome.path]),
                files: FakeFiles([nativeHome.appendingPathComponent("auth.json").path:
                                    #"{"tokens":{"access_token":"fixture"}}"#]),
                keychain: FakeKeychain(), now: { [now] in now }
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nativeHome),
            piUsageScanner: scanner(directory),
            openCodeUsageScanner: OpenCodeCodexUsageScanner(databasePaths: { [] }),
            now: { [now] in now }, pricing: { TestPricing.bundled }
        )
        let successful = await provider.refresh()
        XCTAssertEqual(successful.usageHistory?.series.daily.first?.totalTokens, 165)
        http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        let failed = await provider.refresh()
        XCTAssertEqual(normalizedHistory(failed.usageHistory), normalizedHistory(successful.usageHistory))
        XCTAssertNil(failed.errorCategory)
        XCTAssertNotNil(failed.warning)
        XCTAssertEqual(failed.line(label: "Today"), successful.line(label: "Today"))
    }
    
    func testClaudeOutagePreservesCombinedNativeAndPiHistory() async throws {
        let directory = try fixture(provider: "anthropic")
        let nativeHome = try ClaudeLogFixture.makeHome(files: [
            "session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T14:00:00Z", input: 100, output: 50, costUSD: 0.5
            )
        ])
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: nativeHome)
        }
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": nativeHome.path]),
                files: FakeFiles([nativeHome.appendingPathComponent(".credentials.json").path:
                                    #"{"claudeAiOauth":{"accessToken":"fixture","scopes":["user:profile"]}}"#]),
                keychain: FakeKeychain(), now: { [now] in now }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nativeHome),
            piUsageScanner: scanner(directory),
            now: { [now] in now }, pricing: { .empty }
        )
        let successful = await provider.refresh()
        XCTAssertEqual(successful.usageHistory?.series.daily.first?.totalTokens, 165)
        http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        let failed = await provider.refresh()
        XCTAssertEqual(normalizedHistory(failed.usageHistory), normalizedHistory(successful.usageHistory))
        XCTAssertNil(failed.errorCategory)
        XCTAssertNotNil(failed.warning)
        XCTAssertEqual(failed.line(label: "Today"), successful.line(label: "Today"))
    }
    
    func testEmptyPiHistoryPreservesMissingLoginError() async throws {
        let directory = try fixture(provider: "anthropic")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = codex(directory: directory)
        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.usageHistory)
    }
    
    func testUnknownOnlyCodexPiHistoryWarnsWithoutPeerAggregation() async throws {
        let directory = try fixture(provider: "openai", cost: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = codex(directory: directory)
        let failedLive = await provider.refresh()
        XCTAssertNil(failedLive.errorCategory)
        XCTAssertTrue(failedLive.warning?.contains("Usage totals are unavailable for unknown models: test-model.") == true)
        XCTAssertTrue(failedLive.usageHistory?.series.daily.isEmpty == true)
        let meter = MetricLine.progress(label: "Session", used: 25, limit: 100, format: .percent)
        let successfulLive = await provider.snapshot(mapped: CodexMappedUsage(plan: "Pro", lines: [meter]))
        XCTAssertEqual(successfulLive.warning, "Usage totals are unavailable for unknown models: test-model.")
        XCTAssertEqual(successfulLive.line(label: "Session"), meter)
        XCTAssertNil(successfulLive.line(label: "Today"))
    }
    
    func testUnknownOnlyClaudePiHistoryWarnsWithAndWithoutLiveQuota() async throws {
        let directory = try fixture(provider: "anthropic", cost: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        for signedIn in [true, false] {
            let credentials = signedIn ? [
                directory.appendingPathComponent(".credentials.json").path:
                    #"{"claudeAiOauth":{"accessToken":"fixture","scopes":["user:profile"]}}"#
            ] : [:]
            let provider = ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": directory.path]),
                    files: FakeFiles(credentials), keychain: FakeKeychain(), now: { [now] in now }
                ),
                usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25}}"#.utf8)
                ))),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                piUsageScanner: scanner(directory), now: { [now] in now }, pricing: { .empty }
            )
            let snapshot = await provider.refresh()
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertTrue(snapshot.warning?.contains("Usage totals are unavailable for unknown models: test-model.") == true)
            XCTAssertTrue(snapshot.usageHistory?.series.daily.isEmpty == true)
            XCTAssertNil(snapshot.line(label: "Today"))
            if signedIn {
                XCTAssertNotNil(snapshot.line(label: "Session"))
            }
        }
    }
    
    private func normalizedHistory(_ history: ProviderUsageHistory?) -> ProviderUsageHistory? {
        guard var history else { return nil }
        if let series = history.modelUsage {
            history.modelUsage = ModelUsageSeries(daily: series.daily.map { day in
                DailyModelUsageEntry(date: day.date, models: day.models.sorted { $0.model < $1.model })
            }.sorted { $0.date < $1.date })
        }
        return history
    }
    
    private func codex(directory: URL, cardID: String = "codex", allowed: Bool = true) -> CodexProvider {
        CodexProvider(
            provider: CodexProvider.makeProvider(id: cardID),
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain()),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            piUsageScanner: scanner(directory),
            openCodeUsageScanner: OpenCodeCodexUsageScanner(databasePaths: { [] }),
            allowsUnattributedHistory: allowed,
            now: { [now] in now }, pricing: { .empty }
        )
    }
    
    private func scanner(_ directory: URL) -> PiUsageScanner {
        PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": directory.path]),
            homeDirectory: { directory }, incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
    }
    
    private func fixture(provider: String, cost: Double = 0.25) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiAccount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let message: [String: Any] = [
            "type": "message", "id": "message", "timestamp": "2026-02-20T14:00:00Z",
            "message": [
                "role": "assistant", "provider": provider, "model": "test-model",
                "usage": ["input": 10, "output": 5, "cost": ["total": cost]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: message).write(to: directory.appendingPathComponent("session.jsonl"))
        return directory
    }
}
