# k8s.cluster

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
         ▲ *.k8s.bitulzero.ro (wildcard A record → node IP)
```

## Prerequisites

- [mise](https://mise.jdx.dev) — installs and pins everything else
  (`kubectl`, `helm`, `kubeseal`, Python + Ansible in a project venv):

  ```bash
  mise trust && mise install   # toolchain
  mise run deps                # ansible + hcloud lib + collections
  ```

  Tools are on PATH inside `mise run` tasks and mise-activated shells;
  otherwise prefix with `mise x --` (e.g. `mise x -- kubectl get nodes`).
- A Hetzner Cloud project + API token (goes into `.env`)
- A GitHub repo for this code (private is fine) and, if private, a
  fine-grained PAT with read access to your org's repos
- A domain where you can create one wildcard A record
  (or use `sslip.io` while testing — see below)

## 1. Configure

All provisioning parameters come from environment variables loaded from a
`.env` file (gitignored — mise loads it for every task automatically):

```bash
cp .env.example .env
$EDITOR .env          # set HCLOUD_TOKEN; everything else has sane defaults
```

`.env.example` documents every knob (server type, location, SSH key, k3s
version, GitHub credentials...). Already baked into git (not env-able —
ArgoCD renders what's committed, not your local environment):

- Repo URLs → `github.com/dgmmarin/k8s.cluster`
- Domain → `k8s.bitulzero.ro` (services: `argocd.`, `grafana.`, `demo.` …)
- Let's Encrypt email → `daniel.marin@roweb.com`
  (in `platform/cluster-issuers/`)

> **Dynamic IP?** Leave `ADMIN_IP` empty in `.env`. The playbook detects your
> current public IP on every run and locks SSH/kube-api to it. When your IP
> rotates and you're locked out, just run `mise run firewall` — it refreshes the
> Hetzner firewall rules with your new IP (this talks to the Hetzner API, not
> the node, so it always works).

> **No domain yet?** Use `<name>.<NODE_IP>.sslip.io` as hostnames and keep
> `letsencrypt-staging` as the issuer (prod certs on sslip.io hit shared
> rate limits). Swap once real DNS exists.

## 2. Provision the server + k3s

```bash
mise run provision          # server + firewall + hardening + k3s + ./kubeconfig
mise x -- kubectl get nodes # → one node, STATUS Ready
```

(`KUBECONFIG` is set to `./kubeconfig` by mise inside tasks and activated
shells — no exporting needed.)

The firewall only opens 80/443 publicly; SSH (22) and the Kubernetes API
(6443) are restricted to your `admin_ip`. Everything reaches the cluster
through ingress — NodePorts are unreachable by design.

Now create the DNS record: `*.k8s.bitulzero.ro  A  <node IP>`.

## 3. Bootstrap ArgoCD

```bash
# GITHUB_ORG/GITHUB_TOKEN (in .env) only needed if this repo is private
mise run bootstrap
```

The script installs ArgoCD once, creates the `grafana-admin` secret
(password is printed — **save it**), and applies `bootstrap/root-app.yaml`.
From here on, git is the only interface: ArgoCD syncs the app-of-apps in
`platform/app-of-apps/` in ordered waves (ArgoCD itself → sealed-secrets →
cert-manager → ingress → monitoring → logging → projects).

Watch progress: `kubectl get applications -n argocd -w` or the UI
(`https://argocd.k8s.bitulzero.ro`, user `admin`, password printed by the
script).

**Immediately after `sealed-secrets` is Synced:**

```bash
mise run backup-sealing-key   # store master.key in a password manager, then delete it
```

Without that key, every committed SealedSecret is unrecoverable after a
cluster rebuild.

## 4. Verify end-to-end

1. All Applications in the ArgoCD UI are **Synced / Healthy**.
2. `https://argocd.k8s.bitulzero.ro` and `https://grafana.k8s.bitulzero.ro`
   serve with valid Let's Encrypt certs.
3. Grafana: dashboards show node/pod metrics; **Explore → Loki** →
   `{namespace="argocd"}` returns logs.
4. The demo app answers: `curl https://demo.k8s.bitulzero.ro` (once you
   switch its `clusterIssuer` value to `letsencrypt-prod`, the cert is valid).
5. `free -m` on the node shows ≥ 2.5 GB available.

## Run it locally (k3d)

The full stack runs locally in Docker via [k3d](https://k3d.io) — same k3s,
same bootstrap, same GitOps sync from this repo's `main` branch. No Hetzner
token, no DNS needed:

```bash
mise run local-up          # k3s-in-docker, ports 80/443 on localhost
mise run local-bootstrap   # identical bootstrap; passwords printed
mise x -- kubectl --kubeconfig kubeconfig.local get applications -n argocd -w
```

To use the ingress hostnames, point them at localhost once:

```bash
echo '127.0.0.1 argocd.k8s.bitulzero.ro grafana.k8s.bitulzero.ro demo.k8s.bitulzero.ro' | sudo tee -a /etc/hosts
```

Local caveats:

- **TLS**: Let's Encrypt can't reach a local cluster, so certificates stay
  Pending and ingress serves a self-signed cert — `curl -k` or click through
  the browser warning. Everything else behaves exactly like production.
- **GitOps is still GitOps**: ArgoCD syncs from GitHub `main`, so manifest
  changes must be pushed to show up locally too.
- Teardown: `mise run local-down` (removes the cluster and kubeconfig.local).

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
| Upgrade k3s | Bump `k3s_version` in `ansible/group_vars/all.yml`, run `mise run k3s` (brief API downtime; workloads keep running) |
| OS patching | Automatic (unattended-upgrades); reboot manually during quiet hours if the kernel updates |
| Dynamic IP rotated (SSH/kubectl locked out) | `mise run firewall` — re-allowlists your current public IP via the Hetzner API |
| Refetch kubeconfig | `mise run kubeconfig` |
| Grafana password | `kubectl get secret -n monitoring grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Disk pressure check | Prometheus alert or `df -h /` on the node — Prometheus (10Gi) + Loki (15Gi) + images share the 160 GB disk |

### Disaster recovery

Primary strategy: **rebuild from git** (~30 min). Single-node k3s stores
state in SQLite, not etcd — don't rely on etcd snapshots.

1. `mise run provision` (new server)
2. Restore the sealed-secrets key **before** bootstrapping apps:
   `kubectl create ns kube-system; kubectl apply -f master.key` (from your
   password manager)
3. `mise run bootstrap`, update the DNS record to the new IP

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
mise.toml                 pinned toolchain + all tasks (mise tasks to list)
.env.example              every provisioning parameter, documented
ansible/                  server + firewall + k3s provisioning (mise run provision)
scripts/bootstrap-argocd.sh   one-time ArgoCD install (mise run bootstrap)
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
