# Pi Usage

OpenUsage includes usage from the Pi coding agent on existing provider cards. There is no separate
Pi card. Local history contributes to Today, Yesterday, Last 30 Days, Usage Trend, and model breakdowns.
It does not create subscription quota meters or change the limits returned by a provider's API.

## Which Card Gets the Usage

Attribution uses the provider recorded by Pi, not the model name:

| Pi provider | OpenUsage card |
|---|---|
| `anthropic`, `claude`, `claude-agent-sdk` | Claude |
| `openai`, `openai-codex`, `codex` | Codex |
| `xai`, `grok` | Grok |
| `google-antigravity` | Antigravity |
| `github-copilot` | Copilot |
| `ollama` | Ollama |
| `zai`, `zhipu`, `zai-coding`, `zai-coding-cn`, `zhipu-coding` | Z.ai |
| `opencode`, `opencode-go`, `opencode-zen` | OpenCode |

Provider names are matched without case or surrounding whitespace. Unknown providers and custom
names without an explicit mapping are excluded. For example, a Claude model served through a
gateway is not assigned to the Claude card just because its model name contains “Claude”.

Cursor and OpenRouter keep their existing API sources rather than adding Pi log totals to them.
Cursor reflects usage present in its account export. OpenRouter reflects usage reported for the key
configured in OpenUsage; use the same key in Pi to see that key's usage. Pi credentials are not
imported by this integration.

Claude and Codex keep their existing account safeguards: Pi sessions without a reliable account
identity are excluded when account ownership is ambiguous. Discovering a Pi login does not prove
which account produced every historical Pi session.

## Enabling the Metrics

Grok, Antigravity, and OpenCode combine Pi usage with their existing local history. Copilot, Ollama,
and Z.ai gain Pi-based Usage Trend, Today, Yesterday, and Last 30 Days metrics. All four new metrics
start disabled; enable the ones you want in Customize. Their history covers Pi sessions only, not
all activity billed to those services.

Mapped Pi logs from the last 30 days can satisfy local provider detection for Claude, Codex, Grok,
Antigravity, and OpenCode, subject to their account safeguards. Pi logs alone do not switch on
Copilot, Ollama, or Z.ai; enable those cards and their history metrics in Customize. Existing provider
toggles are still respected. Local Pi history remains available when native credentials are missing
or a live usage request fails; a warning explains why live meters are unavailable.

## Where History Comes From

OpenUsage scans JSONL session files recursively, checking these locations in order:

1. `PI_CODING_AGENT_SESSION_DIR`, when set.
2. `PI_CODING_AGENT_DIR/sessions`, when the Pi config directory is overridden.
3. `~/.pi/agent/sessions/` by default.

Set overrides in the environment available to OpenUsage as well as Pi. Unchanged files reuse a
local parse cache shared across provider cards. Replayed copies of the same message count once,
and days follow your Mac's local time zone. Unreadable logs are reported rather than treated as
proof of zero usage.

Both assistant messages and separate `usage` records contribute to history when they name a mapped
provider. Separate records include billed work such as cache warming. Pi's compaction and branch
summary records can carry usage but omit its provider and model; these costs cannot be assigned
reliably to a provider card. OpenUsage skips them and records a warning in its log. See Pi's
[session format](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md).

Positive costs recorded by Pi are used directly. Missing or zero costs fall back to the shared
[model pricing](../pricing.md) engine; these figures represent API-equivalent usage, not a
subscription bill. Models that cannot be priced are excluded from cost and token totals and listed
in the unknown-model warning, following the same rules as other local spend sources. When all
history is unpriced, the provider warning still names those models even though spend rows are empty.
