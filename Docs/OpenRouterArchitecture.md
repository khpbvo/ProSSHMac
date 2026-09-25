# OpenRouter AI architecture

The terminal assistant uses one OpenRouter Chat Completions connection. `AppDependencies` creates a `KeychainOpenRouterAPIKeyStore`, `OpenRouterClient`, `OpenRouterModelStore`, and `AIAgentService`. The terminal tool handler and its patch approval gate remain in the app. No provider adapter or local Ollama connection is used.

## Settings and upgrade

Settings saves one OpenRouter key in Keychain service `nl.budgetsoft.ProSSHMac.openrouter`, account `api-key`. `OpenRouterModelStore` saves only the explicitly chosen slug in `ai.openrouter.model`; an old provider/model selection never chooses it. It also caches the selected model's metadata so its name and context bound remain available during a catalog outage. Settings refreshes the authenticated model catalog when opened and offers a manual refresh. Only models advertising `tools` with text input and output are listed. The picker shows name, slug, context length, and published per-million-token prices. A failed refresh leaves the last selection usable; a successful refresh that omits it marks the selection unavailable until another model is chosen, including after an app restart.

At the first ordinary app launch after upgrade, `LegacyProviderKeyCleanup` deletes the five known old Keychain services, including `nl.budgetsoft.ProSSHV2.openai`, in both Keychain variants. It clears old provider/model/logging defaults and sets its completion marker only if all deletions succeed. A Keychain failure leaves the marker unset for a later launch. Tests, screenshots, and throughput benchmarks do not perform migration.

## Request and transcript flow

`AIAgentRunner` snapshots the selected model at the start of each user turn. The next turn can use a different model while keeping the session's user, assistant, tool-call, and tool-result messages. `AIConversationContext` groups messages by complete turn and trims the oldest turns until the selected model's context budget fits; it never splits a call from its result. A model switch removes reasoning fields from earlier assistant messages while preserving text and tool history. With the same model, `reasoning_details` is replayed unchanged.

`OpenRouterClient` sends streamed Chat Completions with `provider.require_parameters=true` so routed endpoints must accept the tool parameters. Its byte-oriented SSE parser assembles fragmented text and parallel tool calls, captures reasoning and final usage, honors cancellation, and rejects incomplete or malformed tool calls before any tool runs. HTTP errors and midstream error frames are returned to the assistant UI. It does not log request or response bodies.

The assistant has no automatic model fallback and no `previous_response_id` continuation. All tool execution, session targeting, direct-action filtering, and patch approval live in the existing tool handler.

## Terminal command completion and chat display

`execute_and_wait` and the remote filesystem helpers share `SessionAIToolCoordinator`'s command path. Each command emits private `OSC 7777;PSB;<random token>` before execution and `OSC 7777;PSW;<token>;<exit status>` on completion. The shell command is quoted and evaluated after the start event, so even malformed command syntax cannot expose the wrapper. The parser reader discards shell echo and repaint output until the start event, then passes real output to the terminal. `TerminalEngine` consumes the completion event without placing it in the grid and passes the status to the matching session's pending command. Tool output comes from the same filtered byte stream, so no screen-text marker search or periodic polling is needed. A timeout still resets terminal SGR attributes.

The chat pane parses fenced code and GFM-style pipe tables into separate views; table cells can scroll horizontally in a narrow sidebar. Paragraph breaks use one line break. The developer prompt asks the model to gather complete diagnostic evidence before drawing conclusions, including compressed memory, swap and pressure on macOS.

## Verification

`OpenRouterClientTests` uses mocked HTTP/SSE fixtures. `OpenRouterSettingsTests`, `AIConversationContextTests`, and `AIAgentServiceTests` cover selection, cleanup/retry, replay, session separation, model changes, and tool approval. See the current OpenRouter migration entry and dated loop log in `Docs/featurelist.md` for build, test, and live-validation status.
