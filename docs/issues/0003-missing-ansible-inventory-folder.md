---
type: Issue
title: "0003: Provisioning fails on a fresh clone: ansible/inventory is missing"
description: Both provision playbooks write ansible/inventory/hosts.yml, but git does not keep the empty folder, so the first run fails.
tags: [ansible, bug]
status: done
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T15:00:00Z }
---

# Problem

On a fresh clone, `mise run provision-netcup` failed after 2.5 s with
`Destination directory ../inventory does not exist`. `.gitignore` ignores
`ansible/inventory/hosts.yml`, and git does not store empty folders, so the
folder does not exist. `mise run provision` (Hetzner) writes the same file
and has the same problem.

# Change

Add `ansible/inventory/.gitkeep`, so git keeps the folder.

# Verification

`mise run provision-netcup` on a clean clone gets past "Write inventory file".
