---
type: Issue
title: "0002: Add a full Hetzner install guide"
description: Add docs/install-hetzner.md, the Hetzner equivalent of docs/install-netcup.md.
tags: [docs, hetzner]
status: done
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T14:00:00Z }
---

# Problem

The netcup path has a full guide (`docs/install-netcup.md`). The Hetzner path
had only the short steps in `README.md`.

# Change

- `docs/install-hetzner.md` covers the API token, `.env`, the tools,
  `mise run provision`, DNS, the bootstrap, the notes login, the checks, the
  firewall for a dynamic IP, disaster recovery, deleting the resources, and
  common problems.
- `README.md` links to the guide in section 2.

# Verification

The guide matches `ansible/playbooks/01-provision.yml`,
`ansible/group_vars/all.yml`, `ansible/roles/base/tasks/main.yml`,
`scripts/bootstrap-argocd.sh`, `mise.toml`, and the sync waves in
`platform/app-of-apps/`. Nobody has run the steps against a real Hetzner
project.
