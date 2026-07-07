# Sealed secrets

Every `*.yaml` file in this directory is synced to the cluster by the
`secrets` Application (each manifest must carry its own `metadata.namespace`).

Commit **SealedSecrets only** — never plain `Secret` manifests. Encrypt with
[kubeseal](https://github.com/bitnami/sealed-secrets) against the cluster:

```bash
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --from-literal=key=value \
  --dry-run=client -o yaml \
| kubeseal --format yaml > platform/secrets/my-secret.sealed.yaml
```

Secrets the platform expects (create after bootstrap if you want them
git-managed instead of the imperative ones the bootstrap script creates):

| Secret | Namespace | Purpose |
|---|---|---|
| `grafana-admin` | `monitoring` | keys `admin-user`, `admin-password` |
| `repo-creds-github` | `argocd` | keys `type=git`, `url=https://github.com/<org>`, `username`, `password` (PAT) + label `argocd.argoproj.io/secret-type: repo-creds` |

**Back up the sealing key** (`make backup-sealing-key`) — without it, all
committed SealedSecrets are unrecoverable after a cluster rebuild.
