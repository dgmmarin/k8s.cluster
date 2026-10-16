---
type: Issue
title: "0005: Use the Let's Encrypt production certificate for demo-app"
description: Switch demo-app from letsencrypt-staging to letsencrypt-prod after the staging certificate was issued.
tags: [tls, chore]
status: done
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T15:00:00Z }
---

# Change

The staging certificate for `demo.k8s.bitulzero.ro` was issued on the
netcup cluster, so `examples/demo-app/chart/values.yaml` now sets
`clusterIssuer: letsencrypt-prod`.

# Verification

After ArgoCD syncs, the certificate issuer is "Let's Encrypt" without
"(STAGING)", and `curl https://demo.k8s.bitulzero.ro/` succeeds without `-k`.
