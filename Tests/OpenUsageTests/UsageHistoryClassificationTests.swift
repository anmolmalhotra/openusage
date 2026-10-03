import XCTest
@testable import OpenUsage

@MainActor
final class UsageHistoryClassificationTests: XCTestCase {
    func testEverySpendProviderHasOneExplicitHistoryClassification() {
        let descriptorSets = [
            AntigravityProvider().widgetDescriptors,
            ClaudeProvider().widgetDescriptors,
            CodexProvider().widgetDescriptors,
            CopilotProvider().widgetDescriptors,
            CursorProvider().widgetDescriptors,
            GrokProvider().widgetDescriptors,
            OllamaProvider().widgetDescriptors,
            OpenCodeProvider().widgetDescriptors,
            ZAIProvider().widgetDescriptors
        ]
        
        for descriptors in descriptorSets {
            XCTAssertTrue(descriptors.contains(where: \.isSpendTile))
            XCTAssertEqual(descriptors.compactMap(\.historyResource).count, 1)
        }
        
        let classifications = Dictionary(uniqueKeysWithValues: descriptorSets.compactMap { descriptors in
            descriptors.compactMap(\.historyResource).first.map { (descriptors[0].providerID, $0.scope) }
        })
        XCTAssertEqual(classifications, [
            "antigravity": .machineLocal,
            "claude": .machineLocal,
            "codex": .machineLocal,
            "copilot": .machineLocal,
            "cursor": .accountWide,
            "grok": .machineLocal,
            "ollama": .machineLocal,
            "opencode": .machineLocal,
            "zai": .machineLocal
        ])
    }
}
