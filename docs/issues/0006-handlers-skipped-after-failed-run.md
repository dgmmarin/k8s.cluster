---
type: Issue
title: "0006: sysctl and sshd changes not applied after a failed provisioning run"
description: A failed play skipped the sysctl reload and sshd restart handlers, so the node kept inotify limit 128 and SSH password login.
tags: [ansible, bug, security]
status: done
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T15:15:00Z }
---

# Problem

Loki showed about 150 lines per minute of
`failed to create fsnotify watcher: too many open files`, labelled with the
`api` container of `notes`. The kubelet returns this error when it cannot
follow a container log. Alloy follows every container log, and the node had
used up its inotify instances.

`/etc/sysctl.d/99-kubernetes.conf` had `max_user_instances = 8192`, but the
live value was the Ubuntu default 128 (143 in use). The same run also wrote
the sshd drop-in that turns off password login, but the running sshd still
offered `password`.

Cause: in the second `provision-netcup` run, the sysctl and sshd tasks
changed their files and notified handlers, then the play failed at the ufw
step (issue 0004). Ansible skips pending handlers when a play fails. In the
third run, the files were already correct, so nothing notified the handlers
again.

# Change

- `ansible/ansible.cfg`: `force_handlers = True`. Notified handlers now run
  even when a later task fails.
- On the netcup node, by hand: `sysctl -p /etc/sysctl.d/99-kubernetes.conf`
  and `sshd -t && systemctl reload ssh`.

# Verification

- `fs.inotify.max_user_instances` is 8192 on the node.
- The SSH server offers only `publickey`, and key login works.
- The Loki error count per minute fell from about 150 to 0 after 15:09 UTC.
  `kubectl logs -f` works again.
