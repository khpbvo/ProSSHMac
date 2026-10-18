---
name: linux-host-operations
description: Package, service and shell idioms per Linux family, and what stalls or misleads commands in this terminal harness
platforms: [linux]
---
# Linux host operations

Use when installing packages, managing services or running root commands on Linux hosts.

## What stalls or misleads here
- **sudo drops the harness's non-interactive settings.** Pass them after sudo:
  `sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y install <pkg>`,
  `sudo systemctl status <unit> --no-pager`, `sudo journalctl -u <unit> --no-pager -n 100`.
- **Confirmation questions are not covered by the environment.** Use the tool's own flag:
  `apt-get -y`, `dnf -y`, `zypper --non-interactive`, `apk add` (no prompt), `ucf`/dpkg
  config questions with `-o Dpkg::Options::=--force-confold` (keep the local file) or
  `--force-confnew`.
- **First connection to a new host** asks to accept its key: `ssh -o
  StrictHostKeyChecking=accept-new`, and `-o BatchMode=yes` where a password must not be asked.
- **Editors and editor-backed commands** (`vi`, `nano`, `crontab -e`, `visudo`, `systemctl
  edit`, `git commit` without `-m`) open a full-screen program. Write the file with
  apply_patch or a heredoc instead, then validate (`visudo -cf <file>`, `crontab <file>`,
  `systemctl daemon-reload`).
- **A timed-out command may still be running.** Read the screen before sending anything else;
  wait, or interrupt it deliberately.
- **Long jobs** (upgrades, builds, large copies) run longer than a tool timeout: start them in
  the background with output to a file (`nohup … > /tmp/job.log 2>&1 &`) or in `tmux`, then
  poll the log.

## Identify the family
`cat /etc/os-release` (ID, ID_LIKE, VERSION_ID); `ps -p 1 -o comm=` for the init system.

## Packages

| Task | Debian/Ubuntu | RHEL/Fedora | SUSE | Alpine |
|---|---|---|---|---|
| Refresh | `apt-get update` | `dnf makecache` | `zypper refresh` | `apk update` |
| Install | `apt-get -y install` | `dnf -y install` | `zypper -n install` | `apk add` |
| Upgrade all | `apt-get -y upgrade` | `dnf -y upgrade` | `zypper -n update` | `apk upgrade` |
| Which package owns a file | `dpkg -S <path>` | `rpm -qf <path>` | `rpm -qf <path>` | `apk info --who-owns <path>` |
| List installed | `dpkg-query -W` | `rpm -qa` | `rpm -qa` | `apk info -v` |
| Held/locked | `apt-mark showhold` | `dnf versionlock list` | `zypper locks` | `/etc/apk/world` pins |

A held lock (`Could not get lock /var/lib/dpkg/lock-frontend`) usually means unattended
upgrades are running: `ps aux | grep -E 'apt|dpkg'`, then wait for them.

## Services

| Task | systemd | OpenRC (Alpine, Gentoo) |
|---|---|---|
| Status | `systemctl status <u> --no-pager` | `rc-service <u> status` |
| Start / restart / reload | `systemctl start/restart/reload <u>` | `rc-service <u> start/restart/reload` |
| Enable at boot | `systemctl enable --now <u>` | `rc-update add <u> default` |
| Logs | `journalctl -u <u> --no-pager -n 200` | `/var/log/messages`, the service's own log |
| Failed units | `systemctl --failed --no-pager` | `rc-status --crashed` |

## Done when
- The command ran to completion with its exit code checked, and nothing was left waiting
  at a prompt (check the screen of every host you touched).
