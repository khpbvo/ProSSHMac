---
name: troubleshooting
description: Method for diagnosing a fault: define the symptom, isolate by layer, compare working and broken, one variable at a time
platforms: [linux, bsd, frr, ios, junos, eos, routeros, vyos]
---
# Troubleshooting

Use when something does not work and the cause is unknown.

## 1. Define the symptom
- What exactly fails, from where to where, since when, every time or intermittently.
- Reproduce it yourself with one command (a `curl`, `ping`, `ssh`, `dig`, a log line) and keep
  that command: it is the test for every step below.
- Ask what changed recently if the user knows; check package, config and login history if not
  (`/var/log/apt/history.log`, `dnf history`, `last`, `show archive`, `show system commit`).

## 2. Isolate by layer
Work upward and stop at the first layer that fails:
1. Link: interface up, errors and drops, duplex, VLAN membership, Wi-Fi association.
2. Addressing: right address and prefix, no duplicate (`arping -D`), gateway reachable.
3. Routing: a route to the destination on this host and a return route on the far end;
   `ip route get <dst>`, `traceroute`/`mtr` both ways.
4. Filtering: host firewall, ACLs, security groups, NAT on the path; counters before and after
   one test.
5. Transport: port listening (`ss -ltnp`), reachable (`nc -vz host port`), MTU (`ping -M do
   -s 1472`).
6. Name resolution: `dig`/`resolvectl query` against the resolver the app uses.
7. Service and application: unit state, logs around the test time, config validation.

## 3. Compare working with broken
- A host, interface or path that works is the fastest reference. Run the same commands on
  both and diff (load baseline-and-diff for more than a few facts).

## 4. Change one variable at a time
- Form one hypothesis, predict what the test command will show, change one thing, run the
  test. Undo the change if the prediction was wrong.
- Keep a short log for the user: hypothesis, change, result.

## 5. Capture when reasoning runs out
- Packet capture at both ends at the same time:
  `tcpdump -ni <if> -c 200 host <peer> and port <p>`; on devices, their capture or `debug`
  with a filter and a time limit.
- Raise log levels for one daemon, reproduce, lower them again.

## 6. Fix and report
- Load change-procedure for the fix.
- Report root cause, the evidence for it, the fix, and whether it was a root-cause fix or a
  workaround with the follow-up still open.

## Done when
- The step 1 test command succeeds, the root cause is stated with its evidence, and
  temporary debug or capture settings are removed.
