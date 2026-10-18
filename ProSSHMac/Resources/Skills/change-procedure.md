---
name: change-procedure
description: Method of procedure for any change to a host or device: pre-checks, steps, post-checks, rollback, staged rollout
platforms: [linux, bsd, frr, ios, junos, eos, routeros, vyos]
---
# Change procedure

Use for any change that alters configuration, packages, services, routing or filtering.

## 1. Pre-checks
- State the goal in one sentence and which hosts it touches.
- Capture the current state you are about to change (config file, `show running-config`,
  rule set, unit status). On several hosts, load baseline-and-diff and capture all of them.
- Write the rollback down before the first step: the exact commands or file to restore.
- Check the path you are connected over. If the change can cut it, load access-safety and arm
  a safety net from the list below.
- Check prerequisites: disk space, package mirror reachable, config syntax tool available,
  maintenance window if the user named one.
- Destructive or irreversible steps: say what they are and get the user's confirmation now,
  before step 1 of the rollout.

## 2. Steps
- Make the smallest change that reaches the goal; one concern per step.
- Keep a copy of every file you edit (`cp -a file file.bak.$(date +%Y%m%d%H%M)`) unless the
  platform keeps versions itself (Junos rollback, `archive`, git-managed config).
- Validate syntax before applying (see the services skill for per-daemon checks).

## 3. Post-checks
- Re-run the pre-check captures and compare: the intended difference, and nothing else.
- Check the definition of done for the area (load routing or services).
- Confirm the safety net is disarmed or committed, and the configuration is saved.

## 4. Rollback
- Trigger: a post-check fails, the path drops, or the user asks.
- Apply the written rollback, then run the post-checks again to prove the old state is back.

## 5. Staged rollout (several hosts)
1. Pick one representative host; run sections 1–3 there.
2. Report the result and anything unexpected before continuing.
3. Apply to the rest, in parallel when they are independent, each with its own post-check.
4. Hosts that depend on each other (routing neighbours, cluster members): change them in an
   order that keeps the service up, and verify after each.

## Safety nets (one line per platform)
- Junos: `commit confirmed 5`, then `commit` once verified (auto-rollback otherwise).
- Cisco IOS/IOS-XE: `reload in 10` before the change, `reload cancel` after; or
  `configure replace flash:<archive> time 300` with `archive` enabled.
- Arista EOS: `configure session <name>` then `commit timer 00:05:00`, confirm with `commit`.
- MikroTik RouterOS: safe mode (Ctrl+X) before the change; leave it to keep the change.
- VyOS: `commit-confirm 5`, then `confirm`.
- nftables/iptables: schedule the restore first, e.g.
  `systemd-run --on-active=5min nft -f /root/nft.backup` or `iptables-apply`; cancel the
  timer once verified.
- Netplan: `netplan try` (reverts after 120 s without confirmation).

## Done when
- Post-checks match the goal on every host, the safety net is resolved, config is saved, and
  the handover lists per host what changed, how it was verified and how to undo it.
