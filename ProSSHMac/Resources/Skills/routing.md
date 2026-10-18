---
name: routing
description: Definition of done for OSPF, BGP and static routing (FRR, router CLIs): adjacencies, routes, reachability, persistence
platforms: [frr, bird, ios, junos, eos, routeros, vyos]
---
# Routing: definition of done

Use when setting up or changing OSPF, BGP or static routes, on Linux (FRR, BIRD) or on a
router. Vendor syntax is yours; this is the checklist the result has to pass.

## Before configuring
- Write down the intended design: routers, router IDs, areas or AS numbers, which interfaces
  take part, which prefixes each router originates, and any filters or redistribution.
- Check the basics on every router: interfaces up with the planned addresses, neighbours
  reachable by ping on the link, the routing daemon installed and running, IP forwarding on
  for Linux (`sysctl net.ipv4.ip_forward`, IPv6 likewise).
- Router IDs unique (cloned VMs often share them; see clone-deduplication).

## Adjacencies on every neighbour
- OSPF: every expected neighbour in Full (or 2-Way between DROthers on broadcast links), on
  both sides; area, timers, MTU and authentication match.
- BGP: every session Established on both sides, with the expected prefix counts received
  and sent; no session stuck in Active or Idle.
- Check from each router, not only the one you changed.

## Routes on both ends
- Each router has the intended prefixes in its routing table (not only in the protocol
  database), with the expected next hop and protocol.
- The return path exists: for every A → B route, B has a route back to A's source.
- No unintended prefixes: no default route leaked, no redistribution loop, no more-specifics
  that should be filtered.
- Static routes: next hop reachable, and a floating static (higher distance) only where a
  backup was intended.

## Reachability
- Ping and traceroute between the networks behind the routers, both directions, sourced from
  the right interface or address (`ping -I`, `ping … source`).
- Test the path a user would take, not only router-to-router.

## Persistence
- Configuration saved: FRR `write memory` (or the file in `/etc/frr/`), IOS/EOS
  `write memory`, Junos `commit`, VyOS `commit` + `save`, RouterOS saves on change.
- Daemon enabled at boot (`systemctl is-enabled frr`, the daemons file enables the protocols).
- After restarting the daemon (or the device, with the user's agreement), adjacencies come
  back and the routes return without manual steps. If your session crosses this router, load
  access-safety before the restart.

## Done when
- Every check above passes on every router involved, and the handover lists the adjacencies,
  the routes and the reachability tests that proved it.
