# AI assistant architecture

The terminal assistant talks to one of two providers, chosen in Settings → AI Assistant:
**OpenRouter** (Chat Completions, any tool-capable model) or **Anthropic** (the Messages API,
Claude models directly). `AIProviderSelection` stores the choice in `ai.provider.selected`;
OpenRouter is the default. Everything below the provider — the agent loop, the tool handler,
patch approval, broadcast targeting, the chat pane — is shared. Design history and the phase log
for the Anthropic provider are in `Docs/Anthropic.md`.

## Components

`AppDependencies` builds both stacks and hands them to `AIAgentService`:

| | OpenRouter | Anthropic |
|---|---|---|
| Key store (Keychain, account `api-key`) | `KeychainOpenRouterAPIKeyStore`, service `nl.budgetsoft.ProSSHMac.openrouter` | `KeychainAnthropicAPIKeyStore`, service `nl.budgetsoft.ProSSHMac.anthropic` |
| Client | `OpenRouterClient` | `AnthropicClient` |
| Model store (defaults `ai.<provider>.*`) | `OpenRouterModelStore` | `AnthropicModelStore` (+ effort) |
| Agent-loop adapter (`AIChatProviding`) | `OpenRouterChatProvider` | `AnthropicChatProvider` |
| Settings | `OpenRouterSettingsViewModel`, `OpenRouterModelPicker` | `AnthropicSettingsViewModel`, `AnthropicSettingsSection`, `AnthropicModelPicker` |

Both key stores use `KeychainGenericPassword` (`Services/AI/AIKeychain.swift`): data-protection
Keychain, readable only while this device is unlocked. Both settings view models subclass
`AIKeySettingsViewModel`, and both clients parse server-sent events with
`ServerSentEventDecoder`.

## Settings and upgrade

**OpenRouter.** The user must choose a model explicitly; `ai.openrouter.model` holds the slug and
the selected model's metadata is cached, so its name and context bound survive a catalog outage.
Settings refreshes the authenticated catalog when opened; only models advertising `tools` with
text input and output are listed, with name, slug, context length and per-million-token prices.
A successful refresh that omits the selection marks it unavailable until another model is chosen.

**Anthropic.** `GET /v1/models` (paginated) lists every model the key can use, newest first, with
context and output limits and capabilities (adaptive thinking, effort levels,
`allowed_fallback_models`); the API publishes no prices. Until the user picks one,
`claude-opus-5-5` is used (not persisted). The effort setting (`low`…`max`, default `medium`) is
lowered per request to the highest level the model supports and omitted for models without
effort. The first Claude turn loads the catalog if it is empty, so the model's limits and refusal
fallback are known.

**Upgrade cleanup.** At the first ordinary launch after the OpenRouter migration,
`LegacyProviderKeyCleanup` deletes the five old Keychain services — including
`nl.budgetsoft.ProSSHMac.llm.anthropic`, which is why the Anthropic key uses a different service —
and the old `ai.provider.active` / `ai.model.active` defaults. It sets its completion marker only
if every deletion succeeds. Tests, screenshots and throughput benchmarks do not run it.

## Request and transcript flow

`AIAgentRunner` resolves the provider, model and context length once per user turn
(`AIAgentService.activeModel()`), so a Settings change never splits one tool loop. The
conversation is stored per session in `AIConversationContext` as provider-neutral turns
(`AITranscriptMessage`: user text, assistant turn, tool result). An assistant turn carries the
provider's own reasoning for replay: OpenRouter's `reasoning_details`/`reasoning`, or Claude's
complete content blocks. Turns written by one provider replay to the other as plain text and tool
calls. History is trimmed by whole oldest turns to fit the model's context budget, never
splitting a call from its result.

**OpenRouter.** Streamed Chat Completions with `provider.require_parameters=true`. A model switch
drops earlier reasoning fields; the same model gets `reasoning_details` back unchanged. The parser
assembles fragmented text and parallel tool calls and rejects malformed tool calls before any
tool runs.

**Anthropic.** Streamed `POST /v1/messages`:
- Request: written in a fixed key order with each earlier Claude turn spliced in byte for byte;
  adaptive thinking with `display: "summarized"` (the reasoning panel shows the summaries) and
  `block_binding.prefix_mismatch_behavior: "drop_block"`; `output_config.effort`; automatic
  prompt caching (`cache_control`); `fallbacks: "default"` for models that allow it; tools with
  `eager_input_streaming`. Never `tool_choice`, `temperature` or disabled thinking (Opus 5.5
  rejects them).
- **Thinking blocks are bound to the conversation prefix** (system prompt, tools, every earlier
  message). Claude turns are replayed verbatim, Claude always receives the full tool set (in
  direct-action mode only the iteration cap applies), and a trim or a changed system prompt or
  tool set strips all thinking once (`AIConversationState.requestHistory`). A model switch keeps
  the blocks; the API drops those the new model can't read.
- Stream: text and thinking deltas go to the chat and reasoning panes; tool input is passed to
  the tool handler as the model wrote it (invalid JSON gets the handler's normal error and
  replays as `{}`). A `refusal` stop surfaces as an error with its category and runs no tools;
  after a mid-stream fallback, only the fallback model's tool calls run and the declined
  model's reasoning is not replayed. `max_tokens` and context-window stops are errors. 429, 5xx
  and 529 are retried twice, honouring `retry-after`.
- Logging (subsystem `com.prossh`, category `AICopilot.Anthropic`, notice level, so `log show`
  keeps it): `request_id` and status, any `input_transformations` entry (a thinking block the
  API dropped, with its reason), and usage including cache writes and reads. No request or
  response content is logged.

Neither provider has automatic switching to the other, and there is no `previous_response_id`
continuation. Tool execution, session targeting, direct-action filtering and patch approval live
in the shared tool handler.

## Terminal command completion and chat display

`execute_and_wait` and the remote filesystem helpers share `SessionAIToolCoordinator`'s command path. Each command emits private `OSC 7777;PSB;<random token>` before execution and `OSC 7777;PSW;<token>;<exit status>` on completion. The shell command is quoted and evaluated after the start event, so even malformed command syntax cannot expose the wrapper. The parser reader discards shell echo and repaint output until the start event, then passes real output to the terminal. `TerminalEngine` consumes the completion event without placing it in the grid and passes the status to the matching session's pending command. Tool output comes from the same filtered byte stream, so no screen-text marker search or periodic polling is needed. A timeout still resets terminal SGR attributes.

The chat pane parses fenced code and GFM-style pipe tables into separate views; table cells can scroll horizontally in a narrow sidebar. Paragraph breaks use one line break. The developer prompt asks the model to gather complete diagnostic evidence before drawing conclusions, including compressed memory, swap and pressure on macOS. The pane header shows the active provider and model.

## Verification

Mocked HTTP/SSE fixtures: `OpenRouterClientTests`, `AnthropicClientTests` (with
`AnthropicTestSupport.swift`). Selection, settings and Keychain naming: `OpenRouterSettingsTests`,
`AnthropicSettingsTests`. Transcript and replay rules: `AIConversationContextTests`,
`AnthropicTranscriptTests`. The agent loop across both providers (tool approval, session
separation, model and provider switches, refusals): `AIAgentServiceTests`. Live validation status
is in `Docs/Anthropic.md` (Phase 6) and the dated entries in `Docs/featurelist.md`.
