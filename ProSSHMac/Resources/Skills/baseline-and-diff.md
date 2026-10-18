---
name: baseline-and-diff
description: Compare several hosts or a before/after state: capture the same read-only facts everywhere, diff, change, diff again
platforms: [linux, bsd, frr, ios, junos, eos, routeros, vyos]
---
# Baseline and diff

Use when a task spans several hosts ("what differs", "make them consistent", "find what is
still identical") or when you need proof that a change did only what it should.

## 1. Choose the facts
- List what the question depends on: identity, packages, services, config files, addresses,
  routes, users, scheduled jobs, firewall rules.
- Pick one read-only command per fact that prints stable, comparable text. Prefer commands
  with machine-friendly output (`ip -br addr`, `ss -ltnH`, `dpkg-query -W`, `rpm -qa | sort`,
  `systemctl list-unit-files --state=enabled --no-pager`, `show running-config`).

## 2. Capture
- Run the same commands on every host, in parallel tool calls with one target_session each.
- Normalise before comparing: sort lists, drop timestamps, PIDs, uptimes, counters and the
  hostname where it is only a prefix.
- Hashes make large files cheap to compare: `sha256sum /etc/ssh/sshd_config /etc/hosts …`;
  read the full file only where hashes differ.
- On many facts, one combined command per host (sections separated by `echo "== name =="`)
  keeps the call count low.

## 3. Compare
Sort every fact into one of three lists:
- **Same everywhere, as intended** (shared config, package versions).
- **Different, as intended** (hostnames, addresses).
- **Wrong**: different where it should match (drift), or the same where it must be unique
  (machine ids, host keys, addresses after cloning; see clone-deduplication).

Show the user the "wrong" list as a table, one row per fact, one column per host.

## 4. Change
Load change-procedure for the fix. The baseline is its pre-check capture.

## 5. Diff again
- Re-run exactly the same capture after the change.
- Every "wrong" row should now be in one of the first two lists, and every other row
  unchanged. Report anything else as a side effect.

## Done when
- The second capture shows no row in the "wrong" list, and no unintended difference against
  the baseline.
