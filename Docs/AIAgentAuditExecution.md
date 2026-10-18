# AI agent audit: execution, credentials and device CLIs

Audit run: 2026-10-18. Ownership: `SessionAIToolCoordinator`, the credential manager
extension, `SessionShellIOCoordinator`, `DeviceCLI`, `CredentialPromptDetector`, and the
device/interactive tool extensions. Read with `AIAgentAudit.md` for the complete audit.
Every function in these seven source files was read, including private helpers, initializers,
deinitializers and meaningful computed properties. Locations below refer to this audit's source
snapshot; function names are the stable lookup key.

## End-to-end paths

1. `AIToolHandler` dispatches `execute_and_wait` and file-helper commands to the provider's
   `executeCommandAndWait` → `SessionManager` forwarding method →
   `SessionAIToolCoordinator.executeCommandAndWait` → `wrappedCommand` → shell channel.
   A private PSB marker hides shell line-editor repaints. Output travels through the parser
   reader → `recordParsedChunk` → `filterToolOutput` → `PendingToolCommand.filter` → engine.
   The engine's private PSW callback (installed by `SessionManager`) calls
   `completeToolCommand`, which resolves the continuation with the command's own output.
2. `run_cli_command` → `executeRunCLICommand` → provider → manager → `executeCLICommand`.
   The same parser reader feeds `DeviceCLICapture.ingest`. The polling loop advances pagers,
   detects returned prompts and questions, and runs the device credential state machine.
   Device output remains visible. Each result becomes JSON in `cliResultJSON`.
3. Credential detection reads the pending command's cursor line, independent of throttled
   screen snapshots. After 300 ms quiet it publishes `awaitingCredential`. Its observer calls
   `credentialWaitsDidChange` → `credentialPromptPublisher` → chat card. Answering shifts
   waiting → verifying and restarts the command timeout; retry notices keep the same card.
4. User hardware bytes, string pastes and `send_input` reach `sendRawShellInputBytes`.
   Credential entry bypasses the recorder and raw-input history, including the early idle
   window. State is checked before and after the awaited send to cover host completion during
   suspension. The actual bytes still reach the selected shell.
5. Decline → manager → coordinator → Ctrl+C → 250 ms settle → declined result. Stop/Clear
   cancel the awaited task and call `cancelCredentialPrompts`. Session teardown calls
   `sessionEnded` so a command with a suspended timeout cannot hang forever.

## Findings and changes

- **Fixed: secret input could be recorded after send suspension.** The raw-input path tested
  credential state only after `await shell.send`. Completion could clear that state before
  control returned. It now remembers the entry state and checks both sides of the suspension.
  `testPasswordIsNotRecordedWhenCompletionOccursDuringSend` forces that exact ordering and
  inspects recorder and history, while confirming the bytes reached the host.
- **Fixed: a slow command send could restart a suspended timeout.** Output may create the
  password wait before `send` returns and the continuation is installed. Registration now
  starts a timeout only while this pending command still owns the session and is not paused.
  It also avoids creating a useless timer after an already completed command.
  `testCredentialPauseDuringSendDoesNotStartANewTimeout` holds send across prompt detection
  and then waits beyond the original timeout.
- **Fixed: device prompt prefix collisions could truncate a running command.** A capture for
  `Router#` previously completed on `Router2#` or `Router utilization 90%`. Completion now
  requires an exact stable base and a structured suffix (mode, RouterOS path or SR OS node), while preserving mode changes.
  `testMatchingPrefixAndPercentOutputDoNotComplete` covers these false positives; existing
  device tests cover config mode, Junos and pagers. Structured-suffix fixtures also cover FortiOS, RouterOS SAFE mode and SR OS paths.
- **Fixed: device rejection notices could briefly remove/recreate the credential card.**
  `% Access denied`, `% Bad secrets` and `% Authentication failed` now count as retry notices.
  An incomplete retry notice also no longer clears the shell verification state.
  `testDeviceAccessDeniedKeepsTheSameCredentialCard` verifies identity across a delayed retry.
- **Fixed: malformed interactive input could partly execute.** `send_input` used to discard
  non-string array elements silently; it now rejects the complete call before sending anything,
  and rejects payloads that resolve to no bytes. `run_cli_command` also rejects embedded CR/LF,
  enforcing its one-command-per-call contract before any device input. Contract regression
  tests live in `AIToolContractTests` under the tool audit's ownership.
- **Fixed: spaced FortiOS prompts were unrecognized.** The shared FortiOS prompt pattern now
  permits whitespace before `#`, including `firewall (root) #`. This preserves the conservative
  device shape while making classification and capture agree. `DeviceCLITests` and the existing
  `ShellIntegrationTests.testFortinetFortiOSPromptRegex` cover spaced prompts and reject
  arbitrary words after a hostname.

Verification is performed once by the root agent to avoid concurrent Xcode builds. Relevant
suites: `SessionAIToolCoordinatorTests`, `DeviceCLITests`, `CredentialPromptDetectorTests`,
`AIToolContractTests`, `ShellIntegrationTests`.
The existing local-zsh cycle, environment restoration, synthetic device pagination and secret
entry tests remain part of these suites. No live provider, remote host or credential was used.

## Complete function trace

All paths in the following tables begin at `ProSSHMac/Services/`. “Reviewed” means the complete
body, direct callers and outputs were inspected; it does not claim every branch was executed.

### SessionAIToolCoordinator.swift

| Line | Function/property | Caller → responsibility / next step |
|---|---|---|
| 30 | `awaitingCredential.didSet` | Every wait transition → manager publisher refresh. |
| 37 | `init` | Manager coordinator setup; no side effects. |
| 39 | `deinit` | Empty nonisolated destructor; pending tasks use weak coordinator captures. |
| 41 | `executeCommandAndWait` | Provider forwarding → validate connection, supersede, send wrapper, install continuation/timeout/cancellation. Slow-send pause fixed. |
| 118 | `wrappedCommand` | Awaited shell command → quoted eval, private markers, scoped noninteractive variables, restore values, retain cwd and exit status. |
| 133 | `executeCLICommand` | Device provider forwarding → send one line, poll capture/credential/pager until final status. |
| 223 | `endCLICommand` | Completion/question/timeout → remove CLI pending state and card. |
| 238 | `stepCLICredentialWait` | CLI polling → detect pause, answer newline, retry or progress. |
| 280 | `supersedePendingCommands` | New shell/CLI command → remove old ownership, interrupt credentials, finish prior shell continuation. |
| 297 | `filterToolOutput` | Parser output batch → CLI ingest or shell echo filter; note visible shell output. |
| 310 | `completeToolCommand` | Engine PSW callback → token check, release card, finish continuation. |
| 323 | `timeoutToolCommand` | Timer/cancel → token check, release state, finish partial output without typing into running program. |
| 337 | `cancelToolCommand` | Task cancellation → interrupt password prompt if present, then finish timed out/cancelled wait. |
| 350 | `isEnteringCredential` | Raw input and pane routing → active card or already visible pending credential prompt. |
| 360 | `declineCredentialPrompt` | Card → remove shell ownership or mark CLI declined; interrupt/settle; resolve decline. |
| 382 | `cancelCredentialPrompts` | Stop/Clear → interrupt every active wait and release pending commands. |
| 401 | `sessionEnded` | Session teardown → clear pending state; finish paused shell command. |
| 414 | `interruptCredentialPrompt` | Decline/cancel/supersede → send raw Ctrl+C and settle. |
| 421 | `startTimeout` | Registration/answer → cancel previous timer and schedule token-bound timeout. |
| 432 | `noteCommandOutput` | Shell output filter → waiting/verifying/progress transitions; arm idle detector. |
| 456 | `armCredentialIdleCheck` | Visible output → one moving-deadline idle task per command. |
| 472 | `checkForCredentialPrompt` | Quiet output → suspend timeout/publish wait; retry notices preserve verification. |
| 502 | `publishCommandCompletion` | Manager/rendering shell integration → deduplicate command block and publish nonce. |
| 525 | `PendingCLICommand.init` | CLI execution → own capture. |
| 529 | `PendingCLICommand.result` | CLI terminal paths → output, status, final prompt, page count and credential note metadata. |
| 558 | `PendingToolCommand.continuation.didSet` | Late registration → immediately resume if result already resolved. |
| 567 | `PendingToolCommand.init` | Shell execution → store immutable token/command/timeout. |
| 573 | `PendingToolCommand.filter` | Shell output → bounded PSB prelude, retained output window, visible data. |
| 601 | `PendingToolCommand.commandOutput` | Result creation → exclude PSW marker, strip terminal escapes and surrounding whitespace. |
| 608 | `PendingToolCommand.cursorLine` | Credential detector → bounded normalized output tail. |
| 612 | `PendingToolCommand.recordAfterAnswer` | Verification → retain at most 4096 bytes for progress detection. |
| 620 | `PendingToolCommand.finish` | All shell exits → idempotent result, cancel timers, resume current/late continuation. |
| 634 | `TerminalPlainText.stripEscapes` | Shell/device normalization → byte-state CSI/OSC removal, optional backspace retention. |
| 659 | `TerminalPlainText.plainText` | Shell result → UTF-8 decode and newline normalization. |

### SessionManager+CredentialPrompt.swift

| Line | Function/property | Caller → responsibility / next step |
|---|---|---|
| 24–26 | `CredentialPromptHandling` requirements | View-model boundary: deduplicated publisher, decline and cancel; implementations below. |
| 30 | `credentialPromptPublisher` | Chat observation → publish manager request only on changes. |
| 35 | `credentialWaitsDidChange` | Coordinator observer → oldest wait mapped to stable card identity and current host label. |
| 56 | `declineCredentialPrompt` | View model → coordinator decline. |
| 61 | `cancelCredentialPrompts` | View model → coordinator cancellation. |
| 67 | `isEnteringCredential` | Pane routing → coordinator credential classification. |

### SessionShellIOCoordinator.swift

| Line | Function/property | Caller → responsibility / next step |
|---|---|---|
| 19 | `init` | Manager setup; no side effects. |
| 21 | `deinit` | Empty nonisolated destructor. |
| 23 | `cancelParserTask` | Session lifecycle → cancel/remove reader task. |
| 28 | `sendShellInput` | Programmatic complete command → validate shell, trim line, send, record command input. `suppressEcho` is currently unused. |
| 62 | `sendRawShellInput` | String bridge / interactive tool → UTF-8 raw byte path. |
| 72 | `sendRawShellInputBytes` | Hardware/paste/string input → validate, send, record only nonsecret input; reentrancy leak fixed. |
| 142 | `logLocalInputFailureIfNeeded` | Raw-send errors → metadata-only bounded/deduplicated local diagnostic. No payload logging. |
| 172 | `shortSessionID` | Diagnostic → short nonsecret identifier. |
| 176 | `startParserReader` | Connected shell → detached accumulator/engine pipeline, snapshot flushing and stream-end teardown. |
| 246 | `recordParsedChunk` | Batched parser pipeline → activity/bytes, AI output filtering, history output, recording. |
| 281 | `ChunkBatchAccumulator.init` | Reader → retain batch stream continuation. |
| 285 | `ChunkBatchAccumulator.push` | Raw channel stream → batch bytes until 4096 threshold or 4 ms timer. |
| 296 | `ChunkBatchAccumulator.finish` | Raw stream end → flush and finish downstream. |
| 301 | `ChunkBatchAccumulator.flush` | Size/timer/end → emit bytes, invalidate stale timer. |
| 308 | `ChunkBatchAccumulator.scheduledFlush` | First byte in batch → 4 ms delay with generation check. |

### AI/DeviceCLI.swift

| Line | Function/property | Caller → responsibility / next step |
|---|---|---|
| 32 | `DeviceCLIPrompt.cursorLine` | Session directory, tool guard, CLI startup → last nonempty screen line. |
| 37 | `DeviceCLIPrompt.classify` | Session directory/tool guard/capture → POSIX/vendor/unknown heuristic. |
| 47 | `DeviceCLIPrompt.base` | CLI capture → stable host/user stem across config modes. |
| 54 | `DeviceCLIPrompt.matches` | Classifier → full Swift String NSRange regex match. |
| 88 | `DeviceCLICapture.init` | CLI start → trim command and learn prompt base. |
| 93 | `ingest` | Output filter → append bounded bytes; reset pager byte fence when trimming. |
| 102 | `didAdvancePager` | Successful pager decision → page count and no-repeat fence. |
| 107 | `poll` | CLI loop → normalized cursor/pager/prompt/question and quiet thresholds. |
| 127 | `cursorLine` | Credential wait → bounded cursor-tail detector. |
| 131 | `byteCount` | Credential wait → prompt offset. |
| 134 | `lineBreak` | Waiting credential → first answer newline at clamped offset. |
| 139 | `rawBytes` | Verification → bytes since answer, with safe offsets. |
| 144 | `finalPrompt` | Completed result → normalized last line. |
| 150 | `output` | Result → remove echo, pager, optional final prompt and whitespace-only margins. |
| 168 | `isPrompt` | Poll/output cleanup → terminal suffix, shape and exact prompt base; false completion fixed. |
| 193 | `DeviceCLIText.isPager` | Poll → supported pager regex. |
| 198 | `isQuestion` | Poll → confirmation/question suffix regex. |
| 203 | `removePagers` | Output formatting → erase pager markers at line start. |
| 212 | `normalize` | Capture/detector → strip escapes, apply CR overwrite and UTF-8-aware backspace. |

### AI/CredentialPromptDetector.swift

| Line | Function | Caller → responsibility / next step |
|---|---|---|
| 45 | `match` | Both pending-command paths → bounded prompt regex, remove pwfeedback stars. |
| 58 | `isRetryNotice` | Progress and idle verification → recognize sudo/ssh/device retry lines. |
| 63 | `cursorLine` | Shell/device pending capture → normalize last 1024 raw bytes and read exact cursor line. |
| 71 | `showsProgress` | Answer verification → complete ordinary line, excluding retries/prompts. |

### AI/AIToolHandler+DeviceCLI.swift and +InteractiveInput.swift

| File:line | Function | Caller → responsibility / next step |
|---|---|---|
| DeviceCLI:8 | `RunCLICommandToolDefinition.definition` | Tool registry → strict CLI schema and explanation of password/question handling. |
| DeviceCLI:38 | `executeRunCLICommand` | Dispatch → parse command/timeout, resolve targets, execute sequentially, serialize per-host results. |
| DeviceCLI:93 | `deviceCLITargets` | POSIX execution/file guards → identify known device prompts before sending wrapper syntax. |
| DeviceCLI:100 | `cliResultJSON` | CLI handler → output bounds, status details, actionable hints and password-wait note. |
| InteractiveInput:8 | `SendInputToolDefinition.definition` | Tool registry → raw-input schema, named keys and user-only password policy. |
| InteractiveInput:33 | `executeSendInput` | Dispatch → parse key array, resolve payload/targets, send raw bytes sequentially, serialize count. |
| InteractiveInput:82 | `resolveKeys` | Interactive handler → concatenate named control sequences or literal strings. |
| InteractiveInput:88 | `keySequence` | Key resolver → case-insensitive terminal escape/control byte mapping. |

Additional directly reviewed shared helper:
`ProSSHMac/Terminal/Features/ShellIntegrationScripts.swift:39`, `vendorPromptPattern(for:)`:
returns each platform's prompt regex for both configured shell integration and AI device
classification. Only the FortiOS whitespace allowance changed; its existing regex suite was
extended with positive and negative fixtures.

## Remaining limits and follow-up evidence

- Device completion remains heuristic. Prompt-renaming commands, unusual banners, escaped
  prompts and custom device formats need actual platform fixtures. A device `enable` password
  flow has synthetic coverage; the prior live run did not exercise it.
- `DeviceCLICapture.poll` normalizes the full retained capture on every 50 ms poll (up to
  4 MB). This is a potential CPU hotspot for very large CLI results. No timing evidence was
  collected, so this run does not claim a performance improvement there.
- Environment values are restored by the shell wrapper, but a previously unexported variable
  becomes exported. `eval` commands that exit/exec the shell or enable errexit can prevent PSW
  completion and restoration. Existing shell tests cover ordinary values, unset variables,
  cwd persistence and nonzero exit; these unusual shell-state cases need a separate wrapper
  design decision.
- The line wrapper and actual command share the terminal's canonical input limit. The current
  test limits wrapper overhead; extremely long commands still need a transport-level solution.
- Shell/CLI ownership is keyed by session. The normal runner is sequential, but independently
  running chats targeting the same terminal can reenter during awaits. Supersede is best
  effort; a fully serialized per-session execution queue is outside this focused change.
- Session teardown removes a pending CLI command; its current result defaults to “superseded”
  rather than explicitly saying the connection ended. It terminates, but the diagnostic can be
  improved alongside typed cancellation/disconnect outcomes.
- Fire-and-forget commands and arbitrary shell password prompts outside an awaited AI command
  remain outside credential detection, as specified by `CredentialPrompt.md`.
- `send_input` has no failure-return channel in `AIAgentSessionProviding`; JSON counts requested
  sends, while lower-level send failures are rendered in the terminal. Reporting actual delivery
  requires a provider protocol change and provider/mock call-site migration.
