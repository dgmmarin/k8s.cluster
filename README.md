# gen.k8s.cluster

Single-node **k3s** cluster on **Hetzner Cloud**, fully managed by **ArgoCD**
(GitOps). This repo is the source of truth for everything: infrastructure
provisioning (Ansible), the platform (ingress, TLS, monitoring, logging), and
the registry of product projects — each of which lives in its own git repo.

```
┌─ Hetzner CPX31 (4 vCPU / 8 GB) ──────────────────────────────────────────┐
│  k3s (traefik disabled, servicelb + local-path kept)                     │
│                                                                          │
│  ArgoCD ──manages──> itself + everything below (from this repo)          │
│    ├── ingress-nginx      :80/:443 on the node IP (klipper servicelb)    │
│    ├── cert-manager       Let's Encrypt via HTTP-01                      │
│    ├── sealed-secrets     encrypted secrets committed to git             │
│    ├── kube-prometheus-stack   metrics + dashboards + alerting           │
│    ├── loki + alloy       centralized logs, 7d retention                 │
│    └── ApplicationSet ──> one Application per file in projects/          │
│                             each project repo holds its own Helm chart   │
└──────────────────────────────────────────────────────────────────────────┘
         ▲ *.k8s.example.com (wildcard A record → node IP)
```

## Prerequisites

- CLI tools: `ansible` (2.15+), `kubectl`, `helm`, `kubeseal`, `python3`
- A Hetzner Cloud project + API token (`export HCLOUD_TOKEN=...`)
- A GitHub repo for this code (private is fine) and, if private, a
  fine-grained PAT with read access to your org's repos
- A domain where you can create one wildcard A record
  (or use `sslip.io` while testing — see below)

## 1. Configure

Replace the placeholders (grep for them — nothing else needs editing):

```bash
# Your GitHub org or username (repo URLs in ArgoCD manifests)
grep -rl 'CHANGEME_ORG' --exclude-dir=.git . | xargs sed -i 's/CHANGEME_ORG/your-org/g'

# Your base domain (one wildcard A record *.k8s.yourdomain.com → node IP)
grep -rl 'k8s\.example\.com' --exclude-dir=.git . | xargs sed -i 's/k8s\.example\.com/k8s.yourdomain.com/g'

# Let's Encrypt registration email
grep -rl 'CHANGEME_EMAIL' --exclude-dir=.git . | xargs sed -i 's/CHANGEME_EMAIL/you@company.com/g'

# Your workstation IP in ansible/group_vars/all.yml (SSH + kube-api firewall)
sed -i "s/CHANGEME_ADMIN_IP/$(curl -4 -s ifconfig.me)/" ansible/group_vars/all.yml
```

Review `ansible/group_vars/all.yml` (server type, location, SSH key path,
k3s version), then commit and push — ArgoCD pulls from the remote repo.

> **No domain yet?** Use `<name>.<NODE_IP>.sslip.io` as hostnames and keep
> `letsencrypt-staging` as the issuer (prod certs on sslip.io hit shared
> rate limits). Swap once real DNS exists.

## 2. Provision the server + k3s

```bash
export HCLOUD_TOKEN=<your token>
make deps        # ansible collections + hcloud python lib
make provision   # server + firewall + hardening + k3s + ./kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes   # → one node, STATUS Ready
```

The firewall only opens 80/443 publicly; SSH (22) and the Kubernetes API
(6443) are restricted to your `admin_ip`. Everything reaches the cluster
through ingress — NodePorts are unreachable by design.

Now create the DNS record: `*.k8s.yourdomain.com  A  <node IP>`.

## 3. Bootstrap ArgoCD

```bash
# GITHUB_ORG/GITHUB_TOKEN only needed if this repo is private:
GITHUB_ORG=your-org GITHUB_TOKEN=ghp_xxx make bootstrap
```

The script installs ArgoCD once, creates the `grafana-admin` secret
(password is printed — **save it**), and applies `bootstrap/root-app.yaml`.
From here on, git is the only interface: ArgoCD syncs the app-of-apps in
`platform/app-of-apps/` in ordered waves (ArgoCD itself → sealed-secrets →
cert-manager → ingress → monitoring → logging → projects).

Watch progress: `kubectl get applications -n argocd -w` or the UI
(`https://argocd.k8s.yourdomain.com`, user `admin`, password printed by the
script).

**Immediately after `sealed-secrets` is Synced:**

```bash
make backup-sealing-key   # store master.key in a password manager, then delete it
```

Without that key, every committed SealedSecret is unrecoverable after a
cluster rebuild.

## 4. Verify end-to-end

1. All Applications in the ArgoCD UI are **Synced / Healthy**.
2. `https://argocd.k8s.yourdomain.com` and `https://grafana.k8s.yourdomain.com`
   serve with valid Let's Encrypt certs.
3. Grafana: dashboards show node/pod metrics; **Explore → Loki** →
   `{namespace="argocd"}` returns logs.
4. The demo app answers: `curl https://demo.k8s.yourdomain.com` (once you
   switch its `clusterIssuer` value to `letsencrypt-prod`, the cert is valid).
5. `free -m` on the node shows ≥ 2.5 GB available.

## Adding a project

A project repo needs a Helm chart (or kustomize/plain manifests) — copy
`examples/demo-app/chart/` as a starting point. Then register it here with
**one file**:

```yaml
# projects/my-api.yaml
name: my-api                                    # also the target namespace
repoURL: https://github.com/your-org/my-api.git
srcPath: deploy/chart                           # path inside the project repo
targetRevision: main
```

Commit, push — ArgoCD creates namespace `my-api` and deploys. Delete the
file and the app is pruned. Rules for project charts:

- **Always set resource requests/limits** (single node — unbounded pods get
  the whole cluster evicted).
- Expose HTTP via an `Ingress` with `ingressClassName: nginx` and the
  `cert-manager.io/cluster-issuer` annotation (staging first, then prod).
- Secrets: `kubeseal` them into `platform/secrets/` (see the README there)
  or into the project's own chart.
- Project apps can't touch platform namespaces or create cluster-scoped
  resources (enforced by the `projects` AppProject).

## Day-2 operations

| Task | How |
|---|---|
| Upgrade a platform component | Bump `targetRevision` in its `platform/app-of-apps/*.yaml`, adjust values, push |
| Upgrade ArgoCD | Same — bump chart version in `argocd.yaml` (keep `scripts/bootstrap-argocd.sh` in sync) |
| Upgrade k3s | Bump `k3s_version` in `ansible/group_vars/all.yml`, run `make k3s` (brief API downtime; workloads keep running) |
| OS patching | Automatic (unattended-upgrades); reboot manually during quiet hours if the kernel updates |
| Refetch kubeconfig | `make kubeconfig` |
| Grafana password | `kubectl get secret -n monitoring grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Disk pressure check | Prometheus alert or `df -h /` on the node — Prometheus (10Gi) + Loki (15Gi) + images share the 160 GB disk |

### Disaster recovery

Primary strategy: **rebuild from git** (~30 min). Single-node k3s stores
state in SQLite, not etcd — don't rely on etcd snapshots.

1. `make provision` (new server)
2. Restore the sealed-secrets key **before** bootstrapping apps:
   `kubectl create ns kube-system; kubectl apply -f master.key` (from your
   password manager)
3. `make bootstrap`, update the DNS record to the new IP

Persistent volume data (Grafana history, Loki logs, project PVCs) is
best-effort: `local-path` volumes die with the disk. Optionally schedule
nightly Hetzner snapshots (`hcloud server create-image`) for point-in-time
recovery. Anything irreplaceable belongs in an external database or object
storage, not on this node.

### Known trade-offs (single node)

- No HA: node reboot = a few minutes of downtime for everything.
- `local-path` PVCs: `ReadWriteOnce`, no snapshots, tied to the node.
- klipper servicelb owns hostPorts 80/443 — don't add other hostNetwork
  workloads on those ports.
- Control-plane targets (etcd/scheduler/controller-manager/kube-proxy) are
  intentionally not scraped — k3s embeds them in one process.

## Repo map

```
ansible/                  server + firewall + k3s provisioning (make provision)
scripts/bootstrap-argocd.sh   one-time ArgoCD install (make bootstrap)
bootstrap/root-app.yaml   the only hand-applied manifest
platform/app-of-apps/     one ArgoCD Application per platform component
platform/<component>/     Helm values / manifests for each component
platform/secrets/         SealedSecrets synced to the cluster
projects/                 one small YAML per product project ← add yours here
examples/demo-app/chart/  reference chart for project repos
```

Pinned versions (2026-07): k3s v1.36.2+k3s1 · argo-cd 10.1.2 · sealed-secrets
2.19.1 · cert-manager v1.20.3 · ingress-nginx 4.15.1 · kube-prometheus-stack
87.10.1 · prometheus-operator-crds 30.0.1 · loki 6.55.0 · alloy 1.10.0
