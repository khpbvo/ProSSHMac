---
name: services
description: Definition of done for a service change: config validated, active, enabled, listening, logs clean, survives restart
platforms: [linux, bsd]
---
# Services: definition of done

Use when installing, configuring, upgrading or restarting a daemon (web server, SSH, DNS,
database, proxy, mail, an app unit).

## Before reloading
Validate the configuration with the daemon's own checker, and fix every error first:

| Service | Check |
|---|---|
| sshd | `sshd -t` (with `-T` to print the effective config) |
| nginx | `nginx -t` |
| Apache | `apachectl configtest` |
| HAProxy | `haproxy -c -f /etc/haproxy/haproxy.cfg` |
| BIND | `named-checkconf`, `named-checkzone <zone> <file>` |
| Postfix / Dovecot | `postfix check` / `doveconf -n` |
| sudoers | `visudo -c` |
| nftables | `nft -c -f <file>` |
| systemd unit | `systemd-analyze verify <unit>` |
| Caddy | `caddy validate --config <file>` |

Prefer `reload` over `restart` where the daemon supports it; it keeps connections.

## Running
- `systemctl is-active <unit>` is `active`, and `systemctl status <unit> --no-pager` shows no
  restart loop (check the "since" time and the restart counter).
- `systemctl is-enabled <unit>` is `enabled` (or the OpenRC/rc.d equivalent), unless the user
  wants it manual.

## Listening
- `ss -ltnp` (TCP) / `ss -lunp` (UDP) shows the process on the expected address and port:
  `0.0.0.0`/`::` versus `127.0.0.1` matters.
- The host firewall allows the port from where clients come (`nft list ruleset`, `ufw status`,
  `firewall-cmd --list-all`).

## Logs
- `journalctl -u <unit> --since "<restart time>" --no-pager` has no errors or warnings that
  point at the change; the daemon's own log files likewise.

## Works from a client
- Exercise the service the way a user would: `curl -sv`, `dig @host`, a new `ssh` login,
  `openssl s_client -connect host:443 -servername <name>` for TLS (certificate name and
  expiry).

## Survives a restart
- Restart the unit once and repeat the checks above. A change that only works until the next
  restart is not done.
- After package upgrades: services restarted onto the new libraries (`needrestart -b` lists
  them where installed).

## Done when
- Config validated, unit active and enabled, listening where intended, logs clean since the
  restart, a client test succeeds, and all of it holds after one more restart.
