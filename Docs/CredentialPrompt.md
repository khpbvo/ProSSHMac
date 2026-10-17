# Credential prompts — the copilot waits, the user types, the password never leaves the Mac

When a copilot command asks for a password (sudo, su, doas, an ssh hop, a key passphrase, a
device `enable` password), the tool call pauses instead of timing out. The chat shows a card
naming the host and the command. The user types the password in that host's terminal, the
command continues, and the model gets the real result. Declining sends Ctrl+C to that host and
tells the model, which carries on with the other hosts and reports what it skipped.

## Overview

**Why.** Today the developer prompt carries a four-rule SUDO section because `execute_and_wait`
times out at a password prompt: the model is told to switch to `execute_command`, read the
screen, end its turn and wait for the user to say "done". `apply_patch` has its own copy
(`sudo -n true` pre-check, a `sudo -v` priming command, `status="sudo_password_required"`).
Live (2026-10-15, the four cloned VMs) the model fired `sudo` on all four hosts and moved on,
leaving every host sitting at a prompt. It "sort of works" only because sudo's per-tty
timestamp lets later commands in the same session through for fifteen minutes once the user
has typed once.

The choreography is the problem, not the model. Fix it in code and delete the rules.

**What the user experiences** (agreed 2026-10-16):

1. A copilot command on Testserv2 hits a password prompt. The tool call does not return yet;
   the model sees nothing.
2. A card appears in the chat, like the patch approval card: "Testserv2 is asking for your sudo
   password", the command underneath, two buttons: **Enter password** and **Decline**.
3. Enter password reveals that session (selects its tab or pane if hidden) and moves keyboard
   focus to its terminal, cursor at the prompt. The chat shows "Waiting for your password on
   Testserv2…". The composer is disabled (it already is for the whole turn), and the only chat
   actions are Decline on the card and the new **Stop** button.
4. The user types the password and Enter. The card collapses to "sudo granted on Testserv2",
   keyboard focus returns to the chat pane, and the tool call returns its normal result when
   the command finishes. The result carries one note that it waited for the user, so the model
   does not misread the delay. The composer becomes editable at turn end, as today.
5. Decline sends Ctrl+C to that session, focus returns to the chat, and the tool returns an
   error to the model: the user declined the password prompt on Testserv2, do not retry it
   there unless asked. The model finishes its turn, does the other hosts, and reports the one it
   skipped. (Decided: Decline never stops the whole run. Stop does that.)

**Stop is new.** The pane has only Clear and Send today, and Clear is the only cancel: it
cancels the agent task and also wipes the messages and the model's memory
(`TerminalAIAssistantViewModel.clearConversation`). The user must be able to abort a run
without losing the chat, so Phase 2 adds a Stop button: cancel the agent task, keep messages
and memory, send Ctrl+C to a host waiting at a prompt. Clear keeps its behaviour and also
sends the Ctrl+C (both go through task cancellation, which already reaches
`executeCommandAndWait`'s `onCancel`).

**Guarantees** (these are code, never prompt rules):

- The password never reaches the AI provider. It is typed in the terminal, not echoed by the
  host, and while a session is at a credential prompt its keystrokes are recorded nowhere: not
  the history index, not the session recorder, not any buffer the copilot reads.
- Typing in the terminal works without the button. The button only moves focus.
- The pause has no timeout. The tool's normal timeout is suspended while the card is up and
  restarts in full once the user has typed. No API request is open during a tool call
  (`AIAgentRunner` returns from the stream before tools run), so waiting costs nothing.
- A wrong password behaves as sudo does: "Sorry, try again." re-raises the prompt, the card
  stays; after sudo's third failure the command exits non-zero and returns as an ordinary
  failed command.
- One host at a time. Tool calls run one after another (`AIToolHandler.executeToolCalls` is a
  sequential loop, and `execute_and_wait` across broadcast targets is sequential too), so at
  most one session is ever waiting and the card never needs a queue. Four hosts that all need
  sudo prompt one after another, each with its own card. The optional "Grant sudo on all
  hosts" button (Phase 3) unlocks them up front instead. The wait state is keyed by session
  anyway, so if concurrent tool execution is ever added the card becomes a list without a
  redesign. Concurrent tool execution is out of scope here.
- Stop (or Clear) during a prompt sends Ctrl+C to the waiting host, so no host is left waiting.
- The prompt text the model sees is the prompt line only (`[sudo] password for kevin:`); the
  typed characters are never echoed by the host, so the screen, the command output and the
  per-turn snapshot stay clean. Phase 1 proves this with a test rather than assuming it.

**Scope.** Awaited copilot commands only: `execute_and_wait`, every command `apply_patch` and the
remote file tools run through `executeCommandAndWait`, and `run_cli_command` (a device `enable`
password). `execute_command` is fire-and-forget (`sendShellInput`): nothing is waiting, so
nothing pauses; the prompt stays visible and the model reads the screen as today. The developer
prompt will say to use `execute_and_wait` for sudo like any other command, so this case becomes
rare.

**Detection.** `CredentialPromptDetector` (pure, `nonisolated`, next to `DeviceCLI.swift`)
classifies the cursor line of the pending command's own output (the text after its last line
break; see Decisions for why not `manager.shellBuffers`):
`[sudo] password for <user>:`, `Password:`, `password:`, `<user>@<host>'s password:`,
`Enter passphrase for key '…':`, `(current) UNIX password:`, `Password for <user>:`,
`doas (<user>@<host>) password:`, sudo's `Sorry, try again.` followed by a prompt. It fires only while a pending awaited command exists
for that session and the cursor line has been sitting on a prompt with no further output for
300 ms (so `Password:` scrolling past in a file never matches). Bounded like every other scan:
the check runs at most once per output batch and reads one line. `TerminalView.swift` already
has a `detectsPasswordPrompt` feeding a dead path (`isMacOSTerminalSafetyModeEnabled` is
hard-coded `false`); Phase 0 deletes it so there is one detector, not three.

**Architecture sketch.**

- `SessionAIToolCoordinator` owns the state: `awaitingCredential: [UUID: CredentialWait]`
  (session, prompt, kind, the command, when it started, phase; at most one entry today).
  `filterToolOutput` (per batch) arms a 300 ms idle check; the check reads the cursor line and
  enters `.waiting`, which cancels the pending command's timeout task. A line break in the
  output (the user pressed Enter) moves to `.verifying` and starts a fresh full timeout.
  `.verifying` ends when a complete ordinary output line arrives (not a retry notice, not a
  prompt), when the idle check finds a non-prompt cursor line, or when the command finishes; a
  re-raised prompt goes back to `.waiting`, so the entry (and the card) never blinks out
  between attempts. `pwfeedback` asterisks never end `.waiting`.
- Decline, cancellation and supersede send Ctrl+C to a session with an entry, then wait 250 ms
  before anything else is sent (SIGINT flushes the tty's queued input). A session that closes or
  drops (`SessionManager.removeSessionArtifacts`) ends its pending command, since a paused
  command has no timeout to end it.
- `SessionManager` publishes `credentialPrompt: CredentialPromptRequest?` (`@Published`) and
  exposes `declineCredentialPrompt(sessionID:)` (sends `0x03`, finishes the pending command
  with `.declined`) and `cancelCredentialPrompts()` (Stop/Clear).
- `CommandExecutionResult` and `CLICommandResult` (both in `Services/AIAgentService.swift`)
  gain `waitedForCredential: Bool` and a `.declined` outcome. `AIToolHandler` formats them: a
  `note` field on success, and `{ok:false, error:"The user declined the password prompt on
  <label>.", hint:"Do not retry sudo on this host unless the user asks. Continue with the other
  hosts and report."}` on decline.
- `SessionShellIOCoordinator.sendRawShellInputBytes` is the user keystroke path: every key,
  paste, pop-out key and `send_input` lands there, and it is where
  `recordingCoordinator.recordInput` and `terminalHistoryIndex.recordRawInput` are called. It
  skips both while `awaitingCredential[sessionID]` is set. The bytes still go to the host.
  (`sendShellInput` is the programmatic line path: quick commands, file browser,
  `execute_command`; it is not involved.)
- `TerminalAIAssistantPane` renders `CredentialPromptCardView` above the composer when
  `sessionManager.credentialPrompt` is set. Enter password calls a new
  `onRevealSession(sessionID)` closure that `TerminalView` wires to `focusSessionAndPane`
  (select the tab, focus the first pane holding the session). Reveal is best effort: a session
  in a pop-out window (nothing records which sessions are popped out) or a session that is only
  a tab while a split layout is shown (Bug 88) cannot be brought forward today; the card then
  says "in its own window" / "not in a visible pane" and the user brings it forward. The Bug 88
  fix, queued next in CLAUDE.md, completes the split-layout case; pop-out tracking stays out of
  scope. The pop-out never hosts the AI pane, so it is only ever a reveal target. Decline calls
  the manager. After a grant, keyboard focus moves to the chat pane (not the composer, which is
  disabled until turn end).
- Device CLIs: `DeviceCLICapture` returns `.awaitingInput(question)` for any `:`/`?` line
  after 2 s of idle. A credential prompt there enters the same wait instead, so `enable` on
  IOS or FRR behaves like sudo.

**Affected files.** `Services/SessionAIToolCoordinator.swift`, `Services/SessionManager.swift`,
`Services/SessionShellIOCoordinator.swift`, `Services/AIAgentService.swift` (result types),
`Services/AI/DeviceCLI.swift` (or a new `CredentialPromptDetector.swift` beside it),
`Services/AI/AIToolHandler.swift` (+RemoteExecution, +DeviceCLI), `Services/AI/AIToolDefinitions.swift`,
`Services/AI/ApplyPatchTool.swift`, `ViewModels/TerminalAIAssistantViewModel.swift`,
`UI/Terminal/TerminalAIAssistantPane.swift`, new `UI/Terminal/CredentialPromptCardView.swift`,
`UI/Terminal/TerminalView.swift` (wire reveal; delete `detectsPasswordPrompt` and the dead
safety-mode path). Tests: new `CredentialPromptDetectorTests`,
`SessionAIToolCoordinatorTests` (fake shell channel, `@MainActor final class`, not `actor`),
`TerminalHistoryIndexTests`, `SessionRecorderTests`, `TerminalAIAssistantViewModelTests`,
`AIToolHandlerTests`, `DeviceCLITests`.

## Phases

- [x] **Phase 0: Detector and pause.** (2026-10-17) `CredentialPromptDetector` with table-driven tests
  (every prompt form above, plus negatives: a `Password:` line followed by more output, a
  shell prompt, a `--More--` pager); delete `detectsPasswordPrompt` and the dead safety-mode
  path in `TerminalView`. `SessionAIToolCoordinator`: enter the wait after 300 ms idle on a
  credential line, suspend the timeout, resume on output, re-enter on a re-raised prompt,
  decline sends `0x03` and finishes `.declined`, task cancellation sends `0x03` to the waiting
  session. Result types carry `waitedForCredential` and `.declined`. Tests drive a fake shell
  channel: prompt then PSW marker after "user input"; three failures then exit 1; a decline; a
  cancellation; a second session prompting after the first resolves; a supersede while waiting.
- [x] **Phase 1: Secret entry.** (2026-10-17) `sendRawShellInputBytes` records nothing while its session is
  awaiting a credential. One test types a known password through the real path and asserts it
  appears in none of: history index raw output or command list, session recording, shell
  buffers, the tool's `commandOutput`, the per-turn screen snapshot. The prompt line itself may
  appear.
- [ ] **Phase 2: The card and Stop.** `SessionManager.credentialPrompt`,
  `CredentialPromptCardView` (host label, command, Enter password, Decline, the "not visible"
  note), "Waiting for your password on <host>…" in the chat, best-effort reveal through
  `focusSessionAndPane`, focus to the chat pane after a grant. The Stop button
  (`TerminalAIAssistantViewModel.stop()`: cancel the task, keep messages and memory). Tests:
  view model and pane state for a prompt, a decline, a Stop with and without a prompt up, Clear
  with a prompt up, the card never outlives its wait (compare Bug 81: look up state that
  outlives the view).
- [ ] **Phase 3: Model-facing cleanup.** Delete the SUDO section from `developerPrompt` and,
  in `apply_patch`, `canUseSudoWithoutPassword`, the `sudo -v` priming command and
  `sudo_password_required`. Keep the plain-first, sudo-on-permission-denied order (always-sudo
  would prompt for unprotected files and create root-owned paths); the sudo retry just runs
  `sudo` without `-n` and pauses like any command. Verify the base64 heredoc write still works
  when sudo prompts (`sudo tee` reads the password from the tty, not stdin). `run_cli_command`
  enters the wait on a device password prompt instead of returning `awaitingInput`. Tool
  result formatting (`note`, decline error+hint). Update the tool descriptions. Optional: a
  "Grant sudo on all hosts" button in the chat toolbar that runs `sudo -v` in every connected
  session through the same wait, one after another, so the user unlocks four VMs once, up
  front.
- [ ] **Phase 4: Live validation.** On the four VMs, user at the keyboard: one host; four hosts
  needing sudo in one task (one card after another); wrong password then right; decline on one
  host and confirm the model continues and reports; Stop while a prompt is up (no host left at
  a prompt, chat kept); a `sudo` inside `apply_patch`; an ssh hop password; `enable` in FRR
  `vtysh`; a session not in a visible pane; and `execute_command` with sudo (no card, prompt
  visible). Docs: `Docs/AIArchitecture.md`, CLAUDE.md (AI section, gotchas),
  `Docs/featurelist.md`.

## Decisions

- Decline is per prompt and the model continues; Stop is the only whole-run cancel. (User,
  2026-10-16.)
- Stop is a new button that keeps the chat; Clear stays as it is. (Claude's call, 2026-10-17,
  after the builder check found no Stop exists.)
- No queue: one host waits at a time because tool execution is sequential; concurrent tool
  execution is out of scope. (Claude's call, 2026-10-17.)
- Reveal is best effort; Bug 88 and pop-out tracking are not prerequisites. (Claude's call.)
- Focus returns to the chat pane after a grant; the composer is re-enabled at turn end as
  today. (Claude's call; cheap to change.)
- `apply_patch` keeps plain-first, sudo only on permission denied. (Claude's call.)
- `execute_command` does not pause. (Claude's call: nothing is awaiting it.)
- Detection is a cursor-line match plus 300 ms idle, not output-stream parsing. (Claude's call:
  the cursor line is what the user sees and is already maintained for device CLIs; the idle
  window avoids false positives from file contents.)

- Detection reads the pending command's own output, not `shellBuffers`: those are throttled
  (up to 200 ms in burst mode) and give the last *non-empty* line, so after a correct password
  with a quiet command (`sudo sleep 10`) they would still show the prompt and re-enter the wait.
  The command's output after its start marker is the exact cursor line and cannot match text
  printed before the command ran. (Phase 0, 2026-10-17.)
- The wait has two phases, `.waiting` and `.verifying`, instead of "resume on any output", so
  a wrong password never makes the card say "granted" and `pwfeedback` asterisks don't end the
  wait. (Phase 0.)
- Supersede while waiting sends Ctrl+C before the new command, and finishes the old command
  only after that, so the old command never sends its timeout reset line (`ESC[0m` + newline)
  into the prompt or the new command. A timed-out command skips that reset whenever a newer
  command already owns the session. (Phase 0; found by the supersede test.)
- Keystrokes go unrecorded not only while the wait is up but also while the awaited command's
  cursor line already matches a prompt (`SessionAIToolCoordinator.isEnteringCredential`). The
  300 ms idle check otherwise leaves a window in which a fast first key or a password-manager
  paste was recorded; a leaked first key also stayed in the history index's typed-input buffer
  and was glued onto the next real command (`hls` for `ls`, found by the Phase 1 test). The
  copilot's own command wrapper is still recorded as input, as before. (Phase 1, 2026-10-17.)
- `CLICommandResult.Status.declined` is formatted for the model already (the exhaustive switch
  in `AIToolHandler+DeviceCLI` needs it); everything else about result formatting stays in
  Phase 3. (Phase 0.)

## Open questions

- Should the idle window be configurable for slow links? 300 ms is a guess; the live phase
  measures it over SSH to the VMs.
- (Resolved) Local shell sessions: every keystroke path, local and SSH, ends in
  `sendRawShellInputBytes`, so one hook covers both.
