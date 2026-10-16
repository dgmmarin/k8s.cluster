---
type: Issue
title: "0004: netcup firewall step fails when ADMIN_IP is empty"
description: The auto-detected admin IP is replaced by the empty ADMIN_IP from group_vars, so the ufw step stops with "admin_ip is empty".
tags: [ansible, netcup, bug]
status: done
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T15:10:00Z }
---

# Problem

With `ADMIN_IP` empty in `.env`, which the docs recommend for a dynamic IP,
`mise run provision-netcup` stopped in the base role with "host_firewall is
on but admin_ip is empty". The inventory had the detected IP.

`02-k3s.yml` loads `group_vars/all.yml` with `vars_files`. In Ansible, play
`vars_files` win over inventory and `add_host` variables, so
`admin_ip: ''` from `all.yml` replaced the detected value.

# Change

The per-host value is now `firewall_admin_ip`, which `all.yml` does not
define. The new name is used in `01-provision-netcup.yml` (`add_host`),
`templates/hosts.yml.j2`, and `roles/base/tasks/main.yml`. `admin_ip` in
`all.yml` stays the input from `.env`.

The Hetzner path is not changed: it uses the cloud firewall and
`host_firewall` stays off.

# Verification

`mise run provision-netcup` with an empty `ADMIN_IP` passes the ufw step
and allows SSH and port 6443 from the detected IP.
