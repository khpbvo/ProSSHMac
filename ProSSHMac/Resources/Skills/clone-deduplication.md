---
name: clone-deduplication
description: Checklist for VMs cloned from one image: find identifiers that must be unique per host and regenerate them
platforms: [linux]
---
# Clone de-duplication

Use when several hosts were cloned from one image or template and should become independent
machines. Load baseline-and-diff and compare all hosts first; fix per host afterwards with
change-procedure (one host first).

## Checklist: read, then regenerate where duplicated

| Item | Read | Regenerate |
|---|---|---|
| Hostname | `hostnamectl --static`, `/etc/hostname` | `hostnamectl set-hostname <name>` |
| `/etc/hosts` | the `127.0.1.1` line | update it to the new name |
| machine-id | `cat /etc/machine-id` | `rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup`; running services keep the old id until the next boot |
| D-Bus id | `cat /var/lib/dbus/machine-id` (often a link to the above) | `dbus-uuidgen --ensure` if it is a separate file |
| SSH host keys | `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` | `rm /etc/ssh/ssh_host_*key*` then `ssh-keygen -A`, reload sshd |
| DHCP DUID / client id | leases in `/var/lib/dhcp/`, `/var/lib/NetworkManager/`; `networkctl status` | systemd-networkd derives it from machine-id; delete the stored DUID and lease for dhclient/NM, renew |
| cloud-init instance | `cloud-init query v1.instance_id`, `/var/lib/cloud/data/instance-id` | `cloud-init clean` (re-runs first-boot modules on reboot: check what they do first) |
| MAC addresses | `ip -br link` | hypervisor setting, not fixable in the guest: tell the user |
| Static addresses | `ip -br addr`, netplan / ifcfg / interfaces files | assign the planned address per host |
| Router IDs | `vtysh -c 'show ip ospf'`, `show bgp summary` | set an explicit router-id per host |
| iSCSI initiator | `/etc/iscsi/initiatorname.iscsi` | `echo "InitiatorName=$(iscsi-iname)" > …`, restart iscsid |
| Monitoring and config agents | Zabbix `Hostname=`, Salt `minion_id`, Puppet certname, Wazuh/OSSEC keys, Datadog/Elastic agent ids | per agent: new name or id, remove the old identity, re-register |
| Domain join | `realm list`, `klist -k` | leave and rejoin per host (needs domain credentials from the user) |

## Order
1. Hostname and `/etc/hosts` first, so logs and agents pick up the new name.
2. machine-id (and with it the networkd DUID), SSH host keys, cloud-init state.
3. Network identity: addresses, router IDs, DHCP leases.
4. Agents and domain joins last; they register under the new identity.
5. A reboot is the user's call. Finish the whole task first, then name which hosts need one
   and why (machine-id, cloud-init state), and reboot only after the user agrees, one host at
   a time.

## Side effects to tell the user
- New SSH host keys: the next connection from any client reports a changed host key.
  The user confirms the new key in the app's known-hosts prompt.
- A new machine-id can give a new DHCP lease, so the host may come back at a different
  address.

## Done when
- A second capture across all hosts shows every item in the table unique per host (or
  intentionally shared), each host reachable under its new identity, and agents reporting
  under the new names.
- Any reboot still pending is named per host in the handover.
