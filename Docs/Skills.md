# Copilot skills

Skills are Markdown playbooks the AI copilot loads when a task calls for one. The system prompt
lists each skill's name and description; the model calls `load_skill` to read the rest. Design
and history: `Docs/NetworkCopilot.md` (Phases 5–6, "Design rules").

## Where they live

| Kind | Location | Notes |
|---|---|---|
| Built in | `ProSSHMac/Resources/Skills/*.md` in the repo | Shipped in the app; the build copies them flat into `Contents/Resources/` |
| Yours | `~/Library/Application Support/ProSSHMac/Skills/*.md` | Settings → AI Assistant → **Open Skills Folder** creates and opens it |

- A file of yours with a built-in skill's `name` replaces that skill.
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
- `description`: one line, at most 200 characters (built-in skills keep to 120). It is sent
  with every request, so say *when* to use the skill, not what is in it.
- `platforms` (optional): `[a, b]` or `a, b`. Returned with the skill; it does not hide it.
- Body: anything Markdown. Built-in skills stay under 80 lines and hold procedures and
  checklists only; rules ("never", "always") live in the system prompt so nothing can conflict.

## Built-in skills

| Skill | For |
|---|---|
| `change-procedure` | Any change: pre-checks, steps, post-checks, rollback, staged rollout, per-platform safety nets |
| `baseline-and-diff` | Comparing hosts, or before/after a change |
| `troubleshooting` | Diagnosing an unknown fault |
| `routing` | Definition of done for OSPF/BGP/static |
| `services` | Definition of done for a daemon change |
| `access-safety` | Changes that the management path runs through |
| `clone-deduplication` | VMs cloned from one image |
| `linux-host-operations` | Package and service idioms; what stalls commands in this terminal |

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
