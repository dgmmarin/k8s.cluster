---
type: Guide
title: Command reference
description: The commands that brought up the netcup cluster and the notes app, the steps to add a new project like notes, and the commands for daily work.
tags: [commands, netcup, projects, operations]
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-19T12:00:00Z }
---

# Command reference

Run all commands from the `k8s.cluster` repo root, unless the step says
otherwise. Run `eval "$(mise activate bash)"` once per shell, so that plain
`kubectl` works. Without it, put `mise x --` before each `kubectl`.

The node is the netcup VPS `152.53.158.215`. For the full install guides, see
[`install-netcup.md`](install-netcup.md) and
[`install-hetzner.md`](install-hetzner.md).

## 1. Bring up the cluster (netcup)

These are the commands that brought up the cluster on 2026-10-16.

```bash
# Toolchain (one time)
mise trust && mise install
mise run deps                       # ansible + collections into ./.venv

# Check SSH key login BEFORE provisioning (provisioning turns off password login)
ssh root@152.53.158.215 'echo ok; grep PRETTY_NAME /etc/os-release; free -m'

# .env: SERVER_IP=152.53.158.215, ADMIN_IP empty (auto-detect), GITHUB_ORG=dgmmarin
cp .env.example .env && $EDITOR .env

# OS hardening + ufw + k3s + ./kubeconfig
mise run provision-netcup
kubectl get nodes                   # one node, Ready

# DNS: *.k8s.bitulzero.ro  A  152.53.158.215

# ArgoCD + root app. It prints the Grafana and ArgoCD passwords. Save them.
mise run bootstrap
kubectl get applications -n argocd -w   # wait until all are Synced/Healthy

# After sealed-secrets is Synced: back up the key, put it in a password manager, delete the file
mise run backup-sealing-key

# Check DNS, certificates, and HTTPS
for h in argocd grafana notes demo; do dig +short @1.1.1.1 $h.k8s.bitulzero.ro; done
kubectl get certificate -A
for h in argocd grafana demo notes; do echo "$h $(curl -s -o /dev/null -w '%{http_code}' https://$h.k8s.bitulzero.ro/)"; done
```

## 2. Set up the notes login

Run in the `notes` repo. Set `NOTES_USER` and `NOTES_PASSWORD` in `.env`. Put
the password in single quotes if it has a `$`.

```bash
KUBECONFIG=../k8s.cluster/kubeconfig mise run seal-auth
git add deploy/basic-auth.sealed.yaml deploy/kustomization.yaml && git commit -m "Seal notes login" && git push

# Check the login
curl -s -o /dev/null -w '%{http_code}\n' https://notes.k8s.bitulzero.ro/                   # 401
curl -s -o /dev/null -w '%{http_code}\n' -u "admin:PASS" https://notes.k8s.bitulzero.ro/   # 200
```

After the first CI run, open the two ghcr.io packages (`notes-api`,
`notes-frontend`) on GitHub and set them to public. GitHub has no API for
this, so use the web UI.

## 3. Add a new project like notes

The example name is `myapp`. The `projects` AppProject accepts only repos
under `https://github.com/dgmmarin/`.

### 3a. Create the project repo

```bash
cd ~/Projects/diverse && mkdir myapp && cd myapp && git init -b main
mkdir -p deploy .github/workflows
cp ../notes/deploy/{kustomization.yaml,ingress.yaml} deploy/
cp ../notes/.github/workflows/images.yml .github/workflows/
cp ../notes/mise.toml ../notes/.env.example .
```

Edit these files:

- `deploy/*.yaml`: your Deployments and Services. Every container must have
  `resources.requests` and `limits`. The node has only 4 GB.
- `deploy/ingress.yaml`: set the host to `myapp.k8s.bitulzero.ro`. Use
  `letsencrypt-staging` first, then `letsencrypt-prod`. The wildcard DNS
  record already covers the new host.
- `images.yml` and `kustomization.yaml`: replace `notes-api` and
  `notes-frontend` with your image names.

```bash
git add -A && git commit -m "Add myapp"
gh repo create dgmmarin/myapp --public --source . --push
# After the first CI run: set the ghcr.io packages to public (web UI)
```

### 3b. Seal secrets (optional)

```bash
kubectl create secret generic my-secret -n myapp --from-literal=key=value \
  --dry-run=client -o yaml \
| KUBECONFIG=../k8s.cluster/kubeconfig kubeseal --format yaml > deploy/my-secret.sealed.yaml
# List the file under resources: in deploy/kustomization.yaml, then commit and push
```

### 3c. Register the project in k8s.cluster

One file registers the project:

```bash
cd ~/Projects/diverse/k8s.cluster
cat > projects/myapp.yaml <<'EOF'
name: myapp                                   # also the namespace
repoURL: https://github.com/dgmmarin/myapp.git
srcPath: deploy
targetRevision: main
EOF
# Add an issue file in docs/issues/ for the change
git add projects/myapp.yaml docs/issues/ && git commit -m "Register the myapp project" && git push
```

### 3d. Install cluster-scoped resources (only if needed)

Project apps cannot create CRDs or other cluster-scoped objects. The platform
installs them, like the notes CRD:

```bash
mkdir platform/myapp-crd && cp your-crd.yaml platform/myapp-crd/
sed 's/notes-crd/myapp-crd/g' platform/app-of-apps/notes-crd.yaml > platform/app-of-apps/myapp-crd.yaml
```

### 3e. Watch the deploy

```bash
kubectl -n argocd annotate app myapp argocd.argoproj.io/refresh=normal --overwrite   # do not wait for the poll
kubectl get applications -n argocd
kubectl -n myapp get pods,ingress,certificate
curl -I https://myapp.k8s.bitulzero.ro
```

Before you add a project, check the free memory. The node was at about 96%
after bootstrap:

```bash
kubectl top node; ssh root@152.53.158.215 'free -m'
```

## 4. Daily work

| Task | Command |
|---|---|
| Deploy app code | `git push` to `main` in the app repo. CI builds the images and commits the tag. ArgoCD deploys it. |
| Deploy a platform change | Edit `platform/` or `projects/`, then commit and push |
| Make ArgoCD check git now | `kubectl -n argocd annotate app <app> argocd.argoproj.io/refresh=normal --overwrite` |
| Hard refresh (stuck app) | The same command with `refresh=hard` |
| App status | `kubectl get applications -n argocd` |
| Pods that are not healthy | `kubectl get pods -A \| awk '$4!="Running" && $4!="Completed" \|\| $5>0'` |
| Logs | `kubectl -n notes logs -f deploy/api` |
| Restart pods | `kubectl -n notes delete pod -l app=api`. Do not use `rollout restart`: it changes the spec, and ArgoCD self-heal reverts it. |
| Certificates | `kubectl get certificate -A`, `kubectl get challenges -A` |
| Memory | `kubectl top node`, `kubectl top pod -A --sort-by=memory` |
| ArgoCD password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Grafana password | `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |
| ArgoCD UI without DNS | `kubectl port-forward -n argocd svc/argocd-server 8080:80` |
| Your IP changed (SSH or kubectl blocked) | `mise run netcup-firewall`. If SSH is blocked, first open the netcup VNC console and run `ufw allow from <ip> to any port 22,6443 proto tcp`. |
| Get the kubeconfig again | `mise run kubeconfig` |
| Upgrade k3s | Bump `k3s_version` in `ansible/group_vars/all.yml`, then `mise run k3s` |
| Run provisioning again (idempotent) | `mise run provision-netcup` |
| Rebuild after a disk loss | `mise run provision-netcup`, then `kubectl apply -f master.key`, then `mise run bootstrap` |

### sysctl or sshd changes not applied

If a provisioning run fails partway, check that the node has the sysctl
(inotify) and sshd changes. Issue 0006 describes a run where they were
skipped. If `kubectl logs -f` fails with "too many open files", run:

```bash
ssh root@152.53.158.215 'sysctl -p /etc/sysctl.d/99-kubernetes.conf && sshd -t && systemctl reload ssh'
```
