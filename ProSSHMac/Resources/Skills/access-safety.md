---
name: access-safety
description: Keep the session you are connected over alive while changing sshd, firewalls, interfaces, routes or ACLs
platforms: [linux, bsd, frr, ios, junos, eos, routeros, vyos]
---
# Access safety

Use before any change that the path to the host runs through: sshd, PAM, users and keys,
host firewalls, ACLs, interfaces, addresses, routes, VPNs, NAT.

## 1. Know your path
- Find the address you come from and the interface it arrives on: `echo $SSH_CONNECTION`,
  `ss -tnp | grep sshd`, `who am i`; on devices `show users` / `show system users`.
- Note which interface, route and filter rule carry that traffic. That is what this change
  must leave working.

## 2. Keep a way back
- Ask the user to keep a second session open to the host (or open one in another pane), or
  confirm an out-of-band path: hypervisor console, iLO/iDRAC/IPMI, serial console.
- Arm a timed revert from change-procedure's safety-net list before the change.

## 3. sshd, PAM, users and keys
- Validate with `sshd -t` before reloading; reload rather than restart.
- Test a new login from another pane or with
  `ssh -o BatchMode=yes -o ConnectTimeout=5 user@host true` before closing any existing
  session.
- Changing `AllowUsers`, `PasswordAuthentication`, `PermitRootLogin`, the port or
  `authorized_keys`: confirm the user's own login method still matches.

## 4. Firewalls and ACLs
- Put the rule that allows your management source first, then the rest.
- Apply with a timed revert, verify with a new connection, then cancel the revert.
- Default-deny policies go in last, after the allow rules are confirmed working.

## 5. Interfaces, addresses and routes
- Change the interface you are not connected over first when there is a choice.
- For the management interface: arm a timed revert from change-procedure first, then
  reconnect at the new address if it changed.

## 6. Root work and passwords
- `sudo -n true` tells you whether root commands will stop for a password. If they will, the
  user types it in the terminal when the card appears in the chat; say so before starting a
  run across several hosts, so the user knows to stay at the keyboard.

## Done when
- A fresh login over the normal path works after the change, the timed revert is cancelled
  or committed, and the second session can be closed.
