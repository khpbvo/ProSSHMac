# AI agent audit: prompts, schemas and skills

Audit date: 2026-10-18. This report covers every explicit function and computed property in
`AIToolDefinitions.swift` and `AISkillLibrary.swift`, all eight bundled skill bodies, and
their integration with the runner and handler. Line numbers refer to this audit's source
snapshot. The other audit reports cover the implementations of the exposed tools.

## Trace and function inventory

`AIAgentRunner.run` selects the direct-action tool subset for providers that permit tool-set
changes, snapshots `AISkillLibrary.load()` once per conversation, builds the skill index into
the fixed developer prompt, and passes that same `AISkillSet` to tool dispatch. Handler
`executeSingleToolCall` resolves `load_skill` against that snapshot, rather than rereading disk.
Anthropic keeps the complete tool set and fingerprints the prefix; none of this audit's
changes modifies a skill snapshot or developer prompt during a conversation.

| File:line / function or property | Trace / result |
|---|---|
| `AIToolDefinitions.swift:9` `developerPrompt(skills:)` | Base invariants plus one-line skill index; stable for a fixed snapshot. |
| `AIToolDefinitions.swift:18` `basePrompt` | Harness context, work/verification, sessions, safety and final handover; no domain playbooks added. |
| `AIToolDefinitions.swift:47` `targetSessionProperty` | Shared nullable session argument. Broadcast-default semantics traced to handler/directory. |
| `AIToolDefinitions.swift:52` `buildToolDefinitions(patchToolEnabled:)` | Ten inline tool schemas plus optional patch and send-input/device-CLI definitions; strict objects, required property lists, no extra keys. Corrected search/execute descriptions. |
| `AIToolDefinitions.swift:272` `directActionToolDefinitions(from:)` | Fixed omission of `load_skill`; preserves patch toggle, input ordering and existing unknown-list fallback. |
| `AIToolDefinitions.swift:284` `isDirectActionPrompt` | Trims/case-folds and checks `run `, `execute `, `cd `; intentionally heuristic. |
| `AIToolDefinitions.swift:293` `errorResult` | Serializes shared error object. |
| `AIToolDefinitions.swift:297` `errorObject` | Nonisolated shared `ok/error/hint` contract. |
| `AIToolDefinitions.swift:301` `jsonString` | Stable sorted keys; encoding-failure fallback now also includes an actionable hint. |
| `AIToolDefinitions.swift:311` `shortTraceID` | Eight lowercased UUID characters for correlation, not unique identity/security. |
| `AIToolDefinitions.swift:315` `shortSessionID` | Same short display format for session IDs; full UUID remains tool target. |
| `AIToolDefinitions.swift:319` `elapsedMillis` | Monotonic time, clamps a future start to zero; conversion fits 64-bit Int. |
| `AISkillLibrary.swift:34` `AISkillSet.init` | Sorts skills by name for deterministic prompt index. Loader deduplicates before construction. |
| `AISkillLibrary.swift:38` `skill(named:)` | Exact lookup in immutable per-chat snapshot. |
| `AISkillLibrary.swift:43` `indexLines` | Name and description only; no skill bodies charged every request. |
| `AISkillLibrary.swift:58` `ParseError.errorDescription` | Explicit failures; added flat-front-matter and duplicate-key errors. |
| `AISkillLibrary.swift:90` `load` | Sorted bundled files, sorted user files; user replaces bundled by parsed name. Invalid override leaves bundled entry. |
| `AISkillLibrary.swift:102` `ensureUserDirectory` | Creates only configured user folder; propagates filesystem errors. |
| `AISkillLibrary.swift:108` `skills(in:source:)` | Missing folder yields empty set; hidden files skipped; `.md` case-insensitive; duplicate parsed names keep first sorted filename; logs parse failures. |
| `AISkillLibrary.swift:131` `parse(_:source:)` | CRLF normalization, bounded one-line description, constrained name, optional platforms and nonempty Markdown body. Fixed silently accepted malformed metadata. |

These paths are under `ProSSHMac/Services/AI/`. `AISkill` has only stored data/enum cases and
compiler-generated memberwise initialization. `AISkillLibrary.standard` resolves the bundle
root and Application Support folder; `.empty` is an explicit no-I/O fixture.

## Findings and changes

1. **Skill instruction impossible in direct-action mode.** The prompt says to load an
   applicable skill, but OpenRouter's direct-action subset omitted `load_skill`. Requests such
   as “run the routing checks” could advertise procedures the model could not retrieve.
   Retained `load_skill` in the subset. Regression covers both patch-toggle states.
2. **Metadata silently discarded.** An indented description continuation containing `:` was
   accepted as another field and disappeared from the index; repeated keys silently used the
   last value. The parser now rejects non-flat metadata and duplicate case-insensitive keys.
   Unicode newline characters inside a description are rejected too, preserving the one-line
   index contract. Invalid user overrides preserve the bundled procedure. Format is documented
   in `Docs/Skills.md`; ordinary descriptions containing colons remain supported.
3. **Wrong search/input contracts.** The content-search description implied a uniform rg/grep
   implementation even though local search is in-process literal matching. It now specifies
   literal case-insensitive text, coordinated with the tool audit's remote flag normalization.
   `execute_command` now clearly starts commands at POSIX prompts and directs input for an
   existing program to `send_input`. Shorter descriptions remove misleading guidance.
4. **Restart checklist conflicts with management-path safety.** `services` required an
   unconditional restart after recommending reload for sshd; following it alone could sever
   management access. Its restart procedure now links `access-safety`, requires a tested
   rollback on the management path, and reports deferred restart persistence as unverified.
   The global safety invariant stays in the base prompt.
5. **Error fallback violates its own contract.** Serialization failure returned `ok:false`
   without a hint. The fallback remains valid JSON and now offers another inspection path;
   a non-finite-number regression exercises the otherwise rare failure.
6. **Cross-reference test missed real references.** The test only recognized lowercase
   `load` plus hyphenated names. It now includes `Load`, single-word names, and the second
   target in `load routing or services`.

## Skill graph and cost boundaries

All files below are in `ProSSHMac/Resources/Skills/`; metadata at lines 1–5, body at line 6.
References include explicit `load` instructions and prose references by an exact skill name.
Cycles are procedural context reuse, not executable recursion; the prompt already discourages
unchanged repeated calls. No duplicate auto-loading mechanism was added.

| Skill | References | Description chars / body lines |
|---|---|---|
| `access-safety` | `change-procedure` | 104 / 42 |
| `baseline-and-diff` | `clone-deduplication`, `change-procedure` | 116 / 41 |
| `change-procedure` | `baseline-and-diff`, `access-safety`, `routing`, `services` | 112 / 53 |
| `clone-deduplication` | `baseline-and-diff`, `change-procedure` | 106 / 41 |
| `linux-host-operations` | none | 113 / 54 |
| `routing` | `clone-deduplication`, `access-safety` | 118 / 45 |
| `services` | `access-safety` | 115 / 55 |
| `troubleshooting` | `baseline-and-diff`, `change-procedure` | 119 / 47 |

The eight skill bodies total approximately 20 KB of UTF-8 and load only when requested. The
index carries descriptions of at most 120 characters. User descriptions remain capped at
200. Body/line/byte counts describe repository text, not tokenizer output or measured API
cost. No dollar/iteration improvement is claimed without live Phase 7 comparisons.

## Validation and unresolved risks

Targeted suites: `AIToolDefinitionsTests`, `AISkillLibraryTests`, `BundledSkillsTests`. Parent
audit records actual build/test results; this report does not substitute static review for
those executions. Added regressions cover capability availability, parser information loss,
invalid-override fallback and error-contract serialization.

- `get_command_output` can return only the first 16,000 characters, with no offset; the prompt's
  completeness instruction cannot recover the remainder from that tool alone. Redirecting a
  future command to a file and chunk-reading can work but cannot recover historical output.
  The tool audit records this remaining pagination limitation.
- Same-folder duplicate filenames are deterministic, but user files can override every bundled
  skill, and bodies have no size cap. These are explicit user customization capabilities; very
  large folders/files still imply main-thread synchronous I/O, index growth and request cost.
- Built-in descriptions and “no never/always” checks are length/style guards, not semantic
  proof that procedures agree. Every skill was read; vendor commands, clone identity renewal,
  router rollback timers and real management-path reconnection require platform lab tests.
- The clone checklist's `systemd-machine-id-setup` can derive an ID from platform identity;
  uniqueness must be measured across clones after regeneration. This audit did not modify
  identity commands or run destructive operations on the user's hosts.
- Literal case folding can differ between Swift and host rg/grep locales; remote text-search
  flags now express matching semantics, but exact Unicode collation equivalence is unproven.
- Prompt-only destructive-action confirmation is not a command policy engine; the product
  intentionally relies on a trusted copilot/user workflow and tool-side patch approval.
