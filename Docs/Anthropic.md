# Anthropic — Claude as a Second AI Provider

Add a direct Anthropic Messages API connection next to OpenRouter. The user picks the provider in
Settings → AI Assistant. Each provider has its own key, model choice and catalog. The terminal tool
loop, tool handler, patch approval and chat pane stay shared.

API facts below come from context7 (`/websites/platform_claude_en_api`) and the `claude-api`
skill, both checked 2026-10-15. Swift has no official Anthropic SDK, so this uses raw HTTPS through
`URLSession`, as `OpenRouterClient` already does. Re-check anything marked *verify* against a live
key before relying on it.

## Overview

**Goal.** A user with an Anthropic API key can run the terminal copilot on Claude (default
`claude-opus-5-5`) with streamed text, a readable reasoning panel, every existing tool, and the
same approval gates. Switching provider or model between turns keeps the conversation's text and
tool history.

**Non-goals.** No server tools (web search, code execution), no Managed Agents, no Bedrock/Vertex,
no automatic switching between providers, no OAuth/`ant auth` profiles (API key only).

### Architecture sketch

```
Settings ─ provider: OpenRouter | Anthropic
           ├─ OpenRouter: key (Keychain ...openrouter), model store, catalog       (unchanged)
           └─ Anthropic:  key (Keychain ...anthropic), model store, catalog, effort (new)

AIAgentRunner (per user turn: snapshot provider + model)
   └─ AIConversationState — provider-neutral transcript
        ├─ replay(for: .openRouter) → [OpenRouterMessage]   → OpenRouterClient
        └─ replay(for: .anthropic)  → system + messages     → AnthropicClient
   └─ AIToolHandler (shared, unchanged)
```

- **Neutral transcript.** `AIConversationState` stores turns as provider-neutral messages: user text,
  assistant (text, tool calls, plus an opaque *native payload* tagged with provider and model), and
  tool results. Each client maps neutral → wire. The native payload is how each provider replays
  its own reasoning: OpenRouter's `reasoning_details`/`reasoning`, and Anthropic's full ordered
  assistant `content` array (thinking, text, tool_use blocks) kept as raw JSON.
- **A shared client protocol** (`AIChatProviding`, in `AISharedTypes.swift`): "complete this
  turn" streaming `LLMStreamEvent`s and returning a neutral `AIAssistantTurn`, plus a request-size
  estimate for the context budget. Clients throw on every stop that leaves the turn unusable, so
  there is no stop-kind result. `OpenRouterChatProvider` adapts `OpenRouterServicing`; an
  Anthropic provider conforms the same way. The runner no longer touches `OpenRouterCompletion`.
- **Per-provider stores.** `AnthropicModelStore` mirrors `OpenRouterModelStore` (published state,
  defaults keys `ai.anthropic.*`, cached metadata of the selected model). A small
  `AIProviderSelection` holds the active provider (`ai.provider.selected`).

### Wire protocol (Anthropic Messages API)

- `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`,
  `content-type: application/json`, `anthropic-beta: <comma-separated list>`. Always `"stream": true`.
- Catalog: `GET /v1/models` (paginated: `has_more`, `last_id`, `after_id=`; use `limit=1000`).
  Each entry has `id`, `display_name`, `max_input_tokens`, `max_tokens`, `capabilities`
  (`thinking.types.adaptive`, `effort.{low…max}`, `structured_outputs`, …) and
  `allowed_fallback_models` (published only when the request carries the
  `server-side-fallback-2026-06-01` beta header). No prices.
- Request body:
  - `model`, `max_tokens` = min(64 000, model `max_tokens`). Thinking counts toward it.
  - `system`: the developer prompt as one text block. Frozen for the whole conversation.
  - `tools`: `{name, description, input_schema, strict?, eager_input_streaming: true}` per tool.
    `strict` passes through from `LLMToolDefinition.strict`.
  - `tool_choice` omitted (= `auto`). **Forced `any`/`tool` is a 400 on Opus 5.5, Sonnet 5.5 and
    Fable 5.1**; never send it.
  - `thinking: {"type": "adaptive", "display": "summarized", "block_binding":
    {"prefix_mismatch_behavior": "drop_block"}}` for models whose `capabilities.thinking.types.
    adaptive.supported` is true; omit `thinking` otherwise. **Never** `{"type": "disabled"}` or
    `budget_tokens`: both are a 400 on Opus 5.5. `display` defaults to `"omitted"` (empty
    thinking text), so `"summarized"` is required for the reasoning panel.
  - `output_config: {"effort": <setting>}` when `capabilities.effort.supported`. Opus 5.5's API
    default is `medium`; send it explicitly. Default setting: `medium`.
  - Top-level `cache_control: {"type": "ephemeral"}` (automatic caching of the stable prefix).
  - `fallbacks: "default"` when the model's `allowed_fallback_models` is non-empty, with beta
    `server-side-fallback-2026-07-01`. (The array form needs `-2026-06-01` instead; pairing the
    wrong header with a form is a 400.)
  - Beta header set: `thinking-binding-controls-2026-08-01` (needed for `block_binding`, adds
    `input_transformations` to responses) and `server-side-fallback-2026-07-01` when fallbacks are
    sent. Sending `block_binding` without its header is a 400.
- Messages: user turn = text; assistant turn = the native content array replayed **unchanged**;
  tool results = **one** user message holding every `tool_result` block of that round
  (`tool_use_id`, `content`, `is_error`). Splitting results across messages trains the model away
  from parallel calls.
- Stream events: `message_start` (id, model, usage, `input_transformations`), `content_block_start`
  (`text` | `thinking` | `redacted_thinking` | `tool_use` | `fallback`), `content_block_delta`
  (`text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta`, `citations_delta`),
  `content_block_stop`, `message_delta` (`stop_reason`, `stop_details`, usage), `message_stop`,
  `ping`, `error` (`{"type":"error","error":{"type","message"}}`, e.g. `overloaded_error`).
- Stop reasons: `end_turn`, `tool_use` (run tools), `max_tokens` and
  `model_context_window_exceeded` (incomplete; never run that turn's tools), `refusal` (see below),
  `stop_sequence`, `pause_turn` (server tools only; not expected here, treat as invalid).
- HTTP errors: `{"type":"error","error":{"type","message"}}`. Retry 429, 500, 502, 503, 504, 529
  up to twice, honouring `retry-after`. Log `request-id`, never bodies.

### Rules that shape the design

1. **Preserved thinking (Opus 5.5, Sonnet 5.5, Fable 5.1).** A thinking block's signature binds
   the exact prefix that produced it: the `system` prompt, the `tools` array and every earlier
   message. Editing, removing or reordering an earlier turn, or changing `system`/`tools`
   mid-conversation, invalidates every later thinking block. Accounts created on or after
   2026-08-31 get a 400 for that. Removing a *leading* run of thinking blocks, or all of them,
   is fine. Today's code breaks it in two places:
   - **Context trimming** (`AIConversationState.replay`) drops the oldest turns ("keep-tail
     compaction"), which invalidates the thinking in every turn it keeps.
   - **Direct-action mode** and the `apply_patch` toggle change the `tools` array between turns.

   Design: compute a *prefix fingerprint* (system prompt + tool set + first replayed message) per
   conversation. When it differs from the previous Anthropic request, strip every `thinking` and
   `redacted_thinking` block from the replayed history before sending. Trim only at turn start, so
   the current turn's own blocks are never stripped mid-tool-round. Always send
   `prefix_mismatch_behavior: "drop_block"` as the safety net, so a missed edit degrades (blocks
   dropped, reported in `input_transformations`) instead of failing with a 400. Log
   `input_transformations` entries at debug level.
2. **Model switches keep blocks.** Unlike the OpenRouter path, an Anthropic → Anthropic model
   switch must *not* strip thinking: the API drops what the new model can't read, unbilled, and
   stripping can itself cause ordering/signature 400s. A provider switch replays only that
   provider's native payloads; turns written by the other provider replay as plain text and tool
   calls.
3. **Byte-stable replay.** Replay each assistant content block exactly as received. Keep tool_use
   `input` as the raw accumulated JSON string and splice it into the request body rather than
   re-encoding a dictionary (Swift dictionaries reorder keys). *Verify* in Phase 4 with
   `drop_block` + `input_transformations` that a multi-turn tool session reports no
   `prefix_binding_mismatch`.
4. **Refusals.** `stop_reason: "refusal"` arrives as HTTP 200, before or mid-output. Branch on
   `stop_reason`, not `stop_details` (which may be null). Discard partial output, never run that
   turn's tools, and show the category and explanation when present. With `fallbacks: "default"`
   a `fallback` content block marks each switch point; when echoing that turn, omit `thinking`,
   `redacted_thinking` and `tool_use` blocks that come *before* the last `fallback` block, and
   never execute a `tool_use` from before it. The user is told fallbacks are on (Settings note).
5. **Eager input streaming** means tool inputs are not validated by the API. Parse each
   accumulated `partial_json` strictly as a JSON object; if it fails, do not run the tool and
   return `{"INVALID_JSON": "<raw>"}` as an `is_error` tool_result so the model retries.
6. **Key storage.** `nl.budgetsoft.ProSSHMac.llm.anthropic` is one of the legacy services
   `LegacyProviderKeyCleanup` deletes. The new key uses service
   `nl.budgetsoft.ProSSHMac.anthropic`, account `api-key`, data-protection Keychain,
   `WhenUnlockedThisDeviceOnly` — never the legacy name.
7. **Text between tool calls** comes back on Opus 5.5 as progress-update `thinking` blocks;
   `display: "summarized"` returns them mixed with the reasoning summaries, so they show in the
   reasoning panel. No extra beta needed.

### Affected files

New: `Services/AI/AnthropicClient.swift`, `AnthropicTypes.swift`, `AnthropicAPIKeyStore.swift`,
`AnthropicModelStore.swift`, `AnthropicRequestBuilder.swift` (raw-JSON body writer),
`AIProviderSelection.swift`, `ViewModels/AnthropicSettingsViewModel.swift`,
`UI/Settings/AnthropicModelPicker.swift`; tests `AnthropicClientTests`,
`AnthropicSettingsTests`, `AnthropicTranscriptTests`.

Changed: `AIConversationContext.swift` (neutral transcript), `AISharedTypes.swift` (neutral types,
`AIChatProviding`), `AIAgentRunner.swift`, `AIAgentService.swift`, `OpenRouterClient.swift`
(conform to the shared protocol), `App/AppDependencies.swift`, `UI/Settings/SettingsView.swift`,
`UI/Terminal/TerminalAIAssistantPane.swift` (provider · model label), existing AI tests,
`Docs/OpenRouterArchitecture.md` (→ AI architecture covering both providers).

## Phases

- [x] **Phase 0: Spec and API research.** Done 2026-10-15. This document.

- [x] **Phase 1: Provider-neutral transcript and client protocol (no behaviour change).** Done
  2026-10-15; see "Phase 1 as built" below.
  - Add neutral types: `AITranscriptMessage` (user / assistant / toolResult), `AIAssistantTurn`
    (text, tool calls, provider reasoning), and the `AIChatProviding` protocol.
  - `AIConversationState` stores neutral turns. OpenRouter replay maps them to
    `OpenRouterMessage`, including `reasoning_details` from the native payload; the existing
    "model switch drops reasoning" rule stays for OpenRouter only.
  - `OpenRouterClient` conforms; `AIAgentRunner` uses the protocol and neutral messages.
  - Exit: `AIConversationContextTests`, `AIAgentServiceTests`, `OpenRouterClientTests`,
    `OpenRouterSettingsTests` green with unchanged assertions (adapted only to the new types),
    plus a test that OpenRouter replay of a neutral transcript is byte-identical to before.

- [x] **Phase 2: Anthropic key store, catalog and model store.** Done 2026-10-15; see "Phase 2 as built".
  - `KeychainAnthropicAPIKeyStore` (service `nl.budgetsoft.ProSSHMac.anthropic`; reuse the
    Keychain code by extracting a shared generic-password helper from the OpenRouter store, not
    copying it). Test that the legacy cleanup list never contains the new service.
  - `AnthropicModel` (`id`, `display_name`, `max_input_tokens`, `max_tokens`, adaptive-thinking
    and effort-level capabilities, `allowed_fallback_models`) and `fetchModels()` with pagination
    and the `server-side-fallback-2026-06-01` header.
  - `AnthropicModelStore`: like `OpenRouterModelStore`, but defaults to `claude-opus-5-5` when
    nothing is chosen. Effort setting (`low`/`medium`/`high`/`xhigh`/`max`, default `medium`,
    clamped to what the model supports). Isolated `UserDefaults` suites in tests.
  - Exit: `AnthropicSettingsTests` (mocked `URLProtocol`): pagination, capability parsing,
    selection persistence, unavailable-after-refresh, outage keeps selection, effort clamping.

- [ ] **Phase 3: `AnthropicClient` — request building and the SSE stream.**
  - Raw-JSON request writer: fixed fields encoded with `JSONEncoder`, replayed assistant blocks
    and tool inputs spliced in verbatim.
  - Byte-oriented SSE parser (reuse the OpenRouter line splitter): text, thinking (+signature),
    redacted_thinking, tool_use (+`input_json_delta`), fallback blocks, `message_delta`
    stop_reason/stop_details/usage, `ping`, `error` events. Emit `textDelta`/`reasoningDelta`
    events and `…Done` at the end.
  - Stop handling: `end_turn`, `tool_use`, `max_tokens`/`model_context_window_exceeded` →
    incomplete, `refusal` → `AnthropicError.refused(category, explanation)`, others → invalid.
  - Retries (429/5xx/529 + `retry-after`), cancellation, the 4 MB line cap, provider-specific
    `LocalizedError` messages.
  - Exit: `AnthropicClientTests` with SSE fixtures: text-only, thinking + text, parallel tool
    calls with fragmented JSON, invalid tool JSON, pre-output refusal, mid-stream refusal,
    fallback block, `max_tokens`, `error` event, 529 retry, request headers/body shape
    (no `tool_choice`, `eager_input_streaming`, `thinking`/`output_config`/`fallbacks` gating).

- [ ] **Phase 4: Anthropic transcript replay rules.**
  - Neutral → Anthropic messages: user text, assistant native content replayed unchanged (or
    built from text/tool calls for turns another provider wrote), all tool results of a round in
    one user message, `INVALID_JSON` error results.
  - Prefix fingerprint; strip all thinking on change; trim only at turn start; no stripping on
    Anthropic model switch; fallback-boundary echo rule; `input_transformations` debug logging.
  - Exit: `AnthropicTranscriptTests`: append-only replay is byte-identical across iterations; a
    tool-set change strips thinking once; trimming strips thinking from kept turns; model switch
    keeps blocks; cross-provider history replays as text/tool calls; fallback echo omits pre-
    boundary thinking/tool_use.

- [ ] **Phase 5: Provider selection, wiring and Settings UI.**
  - `AIProviderSelection` (`ai.provider.selected`, default OpenRouter so existing users see no
    change). `AIAgentService`/`AIAgentRunner` snapshot provider + model per user turn and route to
    the matching client and context budget (`max_input_tokens`).
  - `AppDependencies` builds both stacks. Settings → AI Assistant: provider picker; Anthropic
    key field (paste/save/remove, masked hint), model picker (name, id, context; no prices),
    effort picker, a note that refusal fallbacks are on. The assistant pane header shows
    "Anthropic · <model>" or "OpenRouter · <model>"; error messages name the active provider.
  - Exit: `AIAgentServiceTests` extended with a mock `AIChatProviding` per provider: provider
    switch mid-conversation, per-turn snapshot, refusal surfaces as an error and runs no tools.
    Build + targeted AI suites green.

- [ ] **Phase 6: Live validation and docs.**
  - With a real key, on a relaunched build: plain question; multi-step tool session
    (`execute_and_wait`, `read_files`, `apply_patch` with approval); reasoning panel shows
    summaries; switch Opus 5.5 → Sonnet 5.5 mid-conversation; switch provider and back; long
    session reports no `prefix_binding_mismatch` in `input_transformations`; cache reads appear in
    `usage.cache_read_input_tokens` from the second request on.
  - Rename/extend `Docs/OpenRouterArchitecture.md` to cover both providers; update CLAUDE.md
    (AI service stack, key files, gotchas: legacy key name, preserved thinking, no forced
    tool_choice).

## Phase 1 as built (2026-10-15)

- `AISharedTypes.swift`: `AITranscriptMessage` (`.user`, `.assistant(AIAssistantTurn)`,
  `.toolResult(LLMToolOutput)`), `AIAssistantTurn` (text, tool calls, `reasoning`),
  `AIProviderReasoning` (one case, `.openRouter(details:text:)`; Phase 4 adds Anthropic's content
  blocks) and `AIChatProviding` (`estimatedRequestBytes`, `complete`). No `AIProvider` enum yet:
  Phase 5 adds it with provider selection.
- `OpenRouterChatProvider.swift` (new): maps the neutral transcript to `OpenRouterMessage`s and back,
  prepends the system prompt, takes `choices.first`, and keeps the old size formula.
  `OpenRouterServicing`, `OpenRouterClient` and `AppDependencies` are unchanged;
  `AIAgentService` builds the adapter (`chatProvider`).
- `AIConversationState` stores neutral turns. `replay` became `fittedHistory(currentTurn:
  contextLength:size:)` (same trimming loop, size from the provider, no system message in the
  result). A model switch still drops all reasoning; Phase 4 makes that OpenRouter-only.
- Tests: `AIAgentServiceTests` passed unchanged (the proof that OpenRouter requests are the same);
  `AIConversationContextTests` adapted plus three new: assistant messages round-trip unchanged
  through the neutral type, a mapped tool cycle encodes byte-identically to hand-built messages,
  and the size estimate equals the old formula. 20/20 in the four AI suites.

## Phase 2 as built (2026-10-15)

- Shared: `OpenRouterAPIKeyStoring` → `AIAPIKeyStoring` and `OpenRouterKeyStoreError` →
  `AIKeychainError` (both now in `AIKeychain.swift`, with `KeychainGenericPassword`, the Keychain
  code extracted from the OpenRouter store); `OpenRouterHTTPSessioning` → `AIHTTPSessioning` (in
  `AISharedTypes.swift`). The OpenRouter key store keeps its service, legacy list and cleanup.
- `AnthropicTypes.swift`: `AnthropicEffort` (ordered `low`…`max`), `AnthropicModel` (decoded from
  `/v1/models` and re-encoded with the same keys for the selection cache; `supportsAdaptiveThinking`,
  `supportedEffortLevels`, `supportsServerFallback`), `AnthropicModelsPage`, `AnthropicError`.
- `AnthropicAPIKeyStore.swift`: `KeychainAnthropicAPIKeyStore`, service
  `nl.budgetsoft.ProSSHMac.anthropic`.
- `AnthropicClient.swift`: `AnthropicServicing` + `AnthropicClient.fetchModels()` (pages of 1000
  via `after_id`, at most 20; `x-api-key`, `anthropic-version: 2023-06-01`,
  `anthropic-beta: server-side-fallback-2026-06-01`; newest first).
- `AnthropicModelStore.swift`: default `claude-opus-5-5` (not persisted), selection cache,
  unavailable-after-refresh, effort setting (default `medium`) with `effort(for:)` clamping to the
  model's highest supported level (nil when it takes none), context/output fallbacks 200 000 /
  64 000 when no metadata is known.
- Tests: `AnthropicSettingsTests` (6), with its own `URLProtocol` fixture keyed by path + query.
  26/26 across the five AI suites. Nothing is wired into the app yet.

## Open questions

- Should Anthropic effort be per-conversation instead of global? Changing top-level effort
  between requests invalidates the prompt cache (not thinking). Start global; revisit after
  Phase 6.
- Count tokens with `POST /v1/messages/count_tokens` instead of the byte estimate for the context
  budget? Only if Phase 6 shows the estimate trimming too early or too late; 1M-context models
  make trimming rare.
- Simple compaction (summarize the whole history into one message) instead of trimming, once
  sessions get long enough to hit the budget.
