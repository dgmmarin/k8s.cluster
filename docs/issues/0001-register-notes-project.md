---
type: Issue
title: "0001: Register the notes project and install its CRD"
description: Add projects/notes.yaml for dgmmarin/notes and a platform Application that installs the Note CRD.
tags: [projects, crd, feature]
status: done
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T13:00:00Z }
---

# Problem

The notes app (github.com/dgmmarin/notes) needs the `Note` CRD. The
`projects` AppProject does not allow cluster-scoped resources from project
repos, so the project cannot install the CRD itself.

# Change

- `projects/notes.yaml` registers `dgmmarin/notes` (`deploy/` on `main`,
  namespace `notes`).
- `platform/notes-crd/note.yaml` holds the CRD.
  `platform/app-of-apps/notes-crd.yaml` syncs it in wave 0, before the
  projects ApplicationSet (wave 5).
- The README has a short section that points to the notes repo.

# Verification

A k3s v1.36.5 container with ingress-nginx v1.15.1 ran the CRD and the
rendered `deploy/`. The app worked, and the login test passed. See
dgmmarin/notes issue 0001.

Not tested: a full platform bootstrap with the new wave-0 Application.
