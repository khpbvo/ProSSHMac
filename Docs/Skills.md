# Copilot skills

Skills are Markdown files you write for the AI copilot: what it cannot know about your hosts
and how you work. The system prompt lists each skill's name and description; the model calls
`load_skill` to read the rest. Design and history: `Docs/NetworkCopilot.md` (Phases 5–7,
"Design rules").

**No skills ship with the app.** Eight built-in playbooks (change procedure, routing, clone
de-duplication, …) were removed on 2026-10-20: live runs with and without them showed no fewer
iterations, and their stop-and-confirm steps cost the user extra turns. Opus already knows
generic procedure; see `Docs/NetworkCopilot.md` "Phase 7 results so far".

## Where they live

`~/Library/Application Support/ProSSHMac/Skills/*.md`. Settings → AI Assistant → **Open Skills
Folder** creates and opens it.

- The loader still reads `.md` files at the app bundle's resource root as built-in skills
  (none exist); a user skill with the same `name` would replace one.
- Skills are read when a chat starts. After adding or editing one, start a new chat (Clear).
- A file that does not parse is skipped and logged under the `AICopilot.Skills` category
  (Console.app, subsystem `com.prossh`).

## Format

```markdown
---
name: my-skill
description: One line, under 120 characters: when the copilot should load this
platforms: [linux, junos]
---
# Title

The body: steps, checklists, tables.
```

- `name`: lowercase letters, digits and hyphens.
- `description`: one line, at most 200 characters. It is sent with every request, so say
  *when* to use the skill, not what is in it.
- `platforms` (optional): `[a, b]` or `a, b`. Returned with the skill; it does not hide it.
- Front matter uses one unindented `key: value` per line, with no repeated keys or multiline
  values. A colon inside a description is fine.
- Body: anything Markdown. Keep it short; every load costs tokens. Generic procedure
  ("make a rollback plan", "confirm before changing") makes the model stop and ask more, not
  work better: the removed built-ins showed that.

## Example: a skill only you can write

What no model can know is the best use of a user skill: your hosts, their roles, and what not
to touch. Save as `my-lab.md` in the skills folder:

```markdown
---
name: my-lab
description: The user's lab: hosts, roles, management path, what not to touch. Load for any task on these hosts
platforms: [linux, frr]
---
# My lab

## Hosts
| Host | Address | Role |
|---|---|---|
| lab-r1 | 10.0.0.1 | FRR router, OSPF area 0, uplink to the home network |
| lab-r2 | 10.0.0.2 | FRR router, OSPF area 0 |
| lab-web | 10.0.1.10 | nginx, reverse proxy for the test apps |
| lab-db | 10.0.1.20 | PostgreSQL 16 |

## Management path
- I connect from 192.168.1.0/24 through lab-r1's eth0. Changes to lab-r1's eth0, its
  firewall or its default route can cut every session.
- Out-of-band: the Proxmox console at https://pve.lab.local:8006.

## Do not touch
- lab-db's data directory and `pg_hba.conf` without asking first.
- The `backup` user and its cron jobs on every host.

## Conventions
- Config changes go into the git repo in /etc (etckeeper); commit with a message.
- Hostnames are lowercase with a `lab-` prefix; addresses come from the table above.
```
