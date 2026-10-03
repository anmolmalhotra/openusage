import Foundation

/// Maps a pi session log's `provider` field to the OpenUsage provider whose card its usage belongs on.
/// Pi is a BYO-key agent that drives other providers' models, so its usage is attributed back to the
/// underlying provider (a Claude sub used inside pi lands on the Claude card) rather than shown on a
/// card of its own.
///
/// Only direct provider names and explicit aliases with an existing OpenUsage card are mapped.
/// A gateway belongs to its own card regardless of which model it serves; model names must never
/// imply account ownership. Unrecognized/custom providers stay unmapped until explicitly supported.
enum PiProviderMapping {
    /// pi `provider` value → OpenUsage `Provider.id`.
    static let providerToCard: [String: String] = [
        "anthropic": "claude",
        "claude": "claude",
        "claude-agent-sdk": "claude",
        "openai": "codex",
        "openai-codex": "codex",
        "codex": "codex",
        "cursor": "cursor",
        "xai": "grok",
        "grok": "grok",
        "zai": "zai",
        "zhipu": "zai",
        "zai-coding": "zai",
        "zai-coding-cn": "zai",
        "zhipu-coding": "zai",
        "google-antigravity": "antigravity",
        "github-copilot": "copilot",
        "ollama": "ollama",
        "opencode": "opencode",
        "opencode-go": "opencode",
        "opencode-zen": "opencode",
        "openrouter": "openrouter"
    ]

    /// The OpenUsage card id for a pi provider, or nil when pi used a provider OpenUsage doesn't track.
    static func cardID(forPiProvider provider: String) -> String? {
        providerToCard[provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
