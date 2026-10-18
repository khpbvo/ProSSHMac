#!/usr/bin/env python3
"""Print the copilot's explicit Swift declarations and source links as Markdown.

This is a lexical inventory, not a Swift call graph or a runtime coverage report.
It includes local helpers, protocol requirements, explicit initializers and computed properties.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
paths = set((ROOT / "ProSSHMac/Services/AI").glob("*.swift"))
paths.update(ROOT / path for path in (
    "ProSSHMac/Services/AIAgentService.swift",
    "ProSSHMac/Services/SessionAIToolCoordinator.swift",
    "ProSSHMac/Services/SessionManager+CredentialPrompt.swift",
    "ProSSHMac/Services/SessionShellIOCoordinator.swift",
    "ProSSHMac/ViewModels/TerminalAIAssistantViewModel.swift",
    "ProSSHMac/ViewModels/AIKeySettingsViewModel.swift",
    "ProSSHMac/ViewModels/OpenRouterSettingsViewModel.swift",
    "ProSSHMac/ViewModels/AnthropicSettingsViewModel.swift",
    "ProSSHMac/UI/Terminal/TerminalAIAssistantPane.swift",
    "ProSSHMac/UI/Terminal/ReasoningStreamView.swift",
    "ProSSHMac/UI/Terminal/PatchApprovalCardView.swift",
    "ProSSHMac/UI/Terminal/CredentialPromptCardView.swift",
    "ProSSHMac/UI/Settings/OpenRouterModelPicker.swift",
    "ProSSHMac/UI/Settings/AnthropicModelPicker.swift",
    "ProSSHMac/UI/Settings/AnthropicSettingsSection.swift",
    "ProSSHMac/UI/Settings/AIAPIKeyFields.swift",
))
modifiers = r"(?:(?:public|private|fileprivate|internal|nonisolated|static|class|final|override|required|convenience|mutating|nonmutating)\s+)*"
declaration = re.compile(r"^\s*" + modifiers + r"(?:func\s+|init[?!]?\s*\(|deinit\b|subscript\s*\()")
computed = re.compile(r"^\s*" + modifiers + r"var\s+\w+\s*:\s*[^=]+\{")
sections = []
total = 0
for path in sorted(paths):
    if not path.is_file():
        raise SystemExit(f"Missing inventory source: {path.relative_to(ROOT)}")
    entries = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if declaration.match(line) or computed.match(line):
            text = line.strip().replace("|", "&#124;")
            relative = path.relative_to(ROOT).as_posix()
            entries.append(f"| [{line_number}](../{relative}#L{line_number}) | `{text}` |")
    total += len(entries)
    relative = path.relative_to(ROOT).as_posix()
    sections.append(f"## {relative}\n\n{len(entries)} declarations.\n\n| Line | Declaration |\n|---|---|\n" + "\n".join(entries))
print("# AI function inventory\n\n"
      "Generated with `python3 scripts/inventory-ai-functions.py`. Explicit functions, local helpers, "
      "protocol requirements, init/deinit and computed properties are included. Synthesized Swift "
      "members, stored closures and unrelated terminal/SSH internals are excluded. "
      "Links refer to the audited source snapshot. This is source coverage, not executed branch coverage.\n\n"
      f"{len(paths)} files, {total} declarations.\n\n"
      "Call paths and review outcomes: [core](AIAgentAuditCore.md), [tools](AIAgentAuditTools.md), "
      "[execution](AIAgentAuditExecution.md), [prompts and skills](AIAgentAuditPrompts.md).\n\n"
      + "\n\n".join(sections))
