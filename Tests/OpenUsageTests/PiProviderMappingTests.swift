//
//  PiProviderMappingTests.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import XCTest
@testable import OpenUsage

final class PiProviderMappingTests: XCTestCase {
    func testDirectProvidersAndExplicitAliasesUseExistingCards() {
        let aliases: [String: [String]] = [
            "claude": ["anthropic", "claude", "claude-agent-sdk"],
            "codex": ["openai", "openai-codex", "codex"],
            "cursor": ["cursor"],
            "grok": ["xai", "grok"],
            "zai": ["zai", "zhipu", "zai-coding", "zai-coding-cn", "zhipu-coding"],
            "antigravity": ["google-antigravity"],
            "copilot": ["github-copilot"],
            "ollama": ["ollama"],
            "opencode": ["opencode", "opencode-go", "opencode-zen"],
            "openrouter": ["openrouter"]
        ]
        for (card, providers) in aliases {
            for provider in providers {
                XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: provider), card, provider)
            }
        }
    }
    
    func testProviderNamesNormalizeWhitespaceAndCase() {
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "  OPENAI-CODEX\n"), "codex")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "\tZAI-Coding-CN "), "zai")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: " OpenRouter "), "openrouter")
    }
    
    func testGatewaysKeepTheirOwnIdentity() {
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "openrouter"), "openrouter")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "github-copilot"), "copilot")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "opencode-go"), "opencode")
        for provider in ["amazon-bedrock", "google-vertex", "vercel-ai-gateway", "azure-openai-responses"] {
            XCTAssertNil(PiProviderMapping.cardID(forPiProvider: provider), provider)
        }
    }
    
    func testUnknownProvidersDoNotMatchModelNamesOrProviderPrefixes() {
        for provider in ["", " \n", "nvidia", "custom", "claude-opus-4", "gpt-5", "openai-codex-3", "zai-custom"] {
            XCTAssertNil(PiProviderMapping.cardID(forPiProvider: provider), provider)
        }
    }
}
