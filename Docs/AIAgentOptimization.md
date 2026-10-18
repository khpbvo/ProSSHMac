# AI agent audit and optimization

## Goal and scope

Trace the copilot from the composer through model selection, conversation replay, streamed
responses, every exposed tool, session I/O, credentials and patch approval. Review the developer
prompt and all bundled skills together. Fix demonstrated bugs and remove contradictory guidance
without expanding the prompt to compensate for harness defects.

This is one audit phase executed by the primary agent and three requested subagents. The trace
is a source-level function inventory plus call-path review; it is not a claim that every branch
has been exercised against a live model, SSH server or network device.

## Plan

- [x] Phase 1: Trace all AI functions, resolve concrete defects, verify the integrated changes.
  1. Primary: service/runner, conversations, both providers, SSE, settings/key storage and chat
     lifecycle. Record the core function inventory and review results.
  2. Subagent 1: tool dispatch, targeting, local/remote files, patch application and approvals.
     Evidence: `AIAgentAuditTools.md`.
  3. Subagent 2: one-shot and CLI command execution, output capture, credential waits, raw input
     recording and cancellation. Evidence: `AIAgentAuditExecution.md`.
  4. Subagent 3: developer prompt, tool descriptions, skill loading and all eight playbooks.
     Evidence: `AIAgentAuditPrompts.md`.
  5. Integrate focused fixes and regression tests. Run the Debug build and affected AI suites
     serially. Record exact results, unresolved findings and remaining live checks below.

## Conventions

Keep provider-neutral transcripts and provider-specific replay constraints. Claude thinking
blocks retain their prefix semantics. Skills remain fixed per conversation. Tools keep explicit
session routing and actionable error hints. Credential bytes must stay out of recording/history.
Do not read keys or use billable provider requests for the audit. Preserve terminal rendering
and input behavior outside the audited paths.

## Results

Completed with the primary agent and three subagents. The reproducible
[function inventory](AIAgentFunctionInventory.md) covers **501 declarations in 48 files**,
including all 13 exposed tools, legacy entry points, both provider paths, UI lifecycle and
eight bundled skills. The review traces source/call paths; it does not claim runtime branch
coverage for every function.

| Workstream | Evidence | Main changes |
|---|---|---|
| Core | [Core report](AIAgentAuditCore.md) | Stop/Clear response and conversation isolation, fallback-animation cancellation, invalid-thinking cleanup before context fitting, injectable patch policy, private error logging. |
| Tools | [Tool report](AIAgentAuditTools.md) | Full-operation approvals, canonical workspace boundaries including missing-leaf symlinks, directory deletion refusal, safe integers, exact diff whitespace, complete-read checks, anchors/parser fixes, cancellation between side effects. |
| Execution | [Execution report](AIAgentAuditExecution.md) | Credential recording race, paused timeout registration, exact device prompt recognition including FortiOS spacing, retry-card continuity, validated raw input and single-line CLI calls. |
| Prompts / skills | [Prompt report](AIAgentAuditPrompts.md) | `load_skill` available in direct mode, strict one-line metadata, literal search/input contracts, safe service restart checklist, complete error hints and skill cross-reference validation. |

## Verification

- Final Debug app build: **BUILD SUCCEEDED**, including the Metal shader.
  Command: `xcodebuild -project ProSSHMac.xcodeproj -scheme ProSSHMac -destination 'platform=macOS' build`.
  Log: `/tmp/prossh-ai-audit-build-final.log`.
- Final selected tests: **314 tests, 0 failures, 0 skipped**, across 28 suites; 35.918 seconds.
  Command uses the same project/scheme/destination with `test` and one
  `-only-testing:ProSSHMacTests/<suite>` for every suite in the table below.
  Log: `/tmp/prossh-ai-audit-verified.log`.
- Result bundle: `~/Library/Developer/Xcode/DerivedData/ProSSHMac-apuwehfwmjarvscgnrnujnpqjbju/Logs/Test/Test-ProSSHMac-2026.10.18_23-37-22-+0200.xcresult`.
- `git diff --check` passed. The initial sandbox-only build could not access Xcode caches;
  required checks were run with approved build/test access.
- Early runs exposed failures in the new symlink, device prompt and credential fixtures,
  plus old unified-diff fixtures whose hunk counts did not match their body. Fixed the
  implementations, isolated the credential fixture's mock reader, and corrected malformed
  hunk metadata while retaining the original content assertions. Final results above are
  from a clean selected-suite run after those corrections.

| Suite | Tests | Suite | Tests |
|---|---:|---|---:|
| AIAgentServiceTests | 28 | AIBroadcastTests | 9 |
| AIConversationContextTests | 9 | AISkillLibraryTests | 10 |
| AIToolContractTests | 19 | AIToolDefinitionsTests | 15 |
| AnthropicClientTests | 10 | AnthropicSettingsTests | 8 |
| AnthropicTranscriptTests | 9 | OpenRouterClientTests | 6 |
| OpenRouterSettingsTests | 3 | TerminalAIAssistantViewModelTests | 23 |
| ReasoningStreamViewTests | 4 | BundledSkillsTests | 4 |
| CredentialPromptDetectorTests | 7 | DeviceCLITests | 14 |
| SessionAIToolCoordinatorTests | 28 | ShellIntegrationTests | 30 |
| LocalWorkspacePatcherTests | 14 | PatchApprovalTrackerTests | 5 |
| RemotePatchCommandBuilderTests | 17 | PatchRoundTripTests | 2 |
| UnifiedDiffApplyTests | 12 | UnifiedDiffCreateTests | 3 |
| UnifiedDiffParserTests | 13 | ApplyDiffContaminationTests | 1 |
| ApplyDiffCreateTests | 3 | ApplyDiffUpdateTests | 8 |

## Remaining work

- NetworkCopilot Phase 7: relaunched-app runs on the four VMs and real/lab devices, compare
  skills enabled/disabled, focus/broadcast behavior, cost and iterations. No live provider
  request, remote mutation or measured cost/speedup claim was made in this audit.
- File-output pagination and bounded remote reads. Current chunk readers transfer whole remote
  files before slicing, and some tool outputs stop at 16,000 characters without an offset.
- Remote patch atomicity, canonical path interpretation and filesystem race hardening.
  Local symlink validation prevents stable escapes but is not a descriptor-based TOCTOU defense.
- Cross-provider tool-ID collision handling, aggregate SSE limits, and measured CLI polling /
  skill-loading performance. The area reports explain constraints and proposed boundaries.

Regenerate the lexical inventory after changing AI sources:
`python3 scripts/inventory-ai-functions.py > Docs/AIAgentFunctionInventory.md`.
