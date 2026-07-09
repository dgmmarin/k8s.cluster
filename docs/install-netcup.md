# Installing on a netcup VPS

End-to-end guide to bring this cluster up on an existing **netcup** VPS (or any
bring-your-own Ubuntu server). netcup gives you a bare VPS with no cloud API, so
we skip Hetzner-style server creation and configure a **host firewall (ufw)** on
the node itself. Everything after the cluster is up (ArgoCD + GitOps) is
identical to the Hetzner path.

Estimated time: ~30 minutes.

---

## 0. Prerequisites

On your **local machine**:

- [mise](https://mise.jdx.dev) installed (`curl https://mise.run | sh`).
- An SSH keypair. Check with `ls ~/.ssh/id_ed25519.pub`; create one if missing:
  ```bash
  ssh-keygen -t ed25519 -C "k3s-admin"
  ```
- This repo cloned, and its GitHub repo URL/domain adjusted to yours if you
  forked it (see `README.md` → "Configure").

A **domain** where you can create one wildcard `A` record (or use `sslip.io`
while testing — no DNS needed).

---

## 1. Order & prepare the netcup VPS

1. In the netcup CCP (Customer Control Panel), order/select a VPS. Recommended
   minimum: **4 vCPU / 8 GB RAM / ≥80 GB disk** (the full platform — Prometheus,
   Loki, Grafana, ingress — needs the headroom). A VPS 1000 G11 or larger works.
2. Install/reinstall the OS as **Ubuntu 24.04 LTS**.
3. Add your SSH public key during install, or set a root password temporarily.
4. Note the VPS **public IPv4 address** — this is your `SERVER_IP`.

### 1a. Confirm root SSH with your key

The playbook connects as `root` over SSH using key auth. Verify:

```bash
ssh root@<SERVER_IP> 'echo ok && cat /etc/os-release | grep VERSION='
```

If it prints `ok` and `VERSION="24.04..."` you're ready. If you only have a
password so far, install your key first:

```bash
ssh-copy-id root@<SERVER_IP>
```

> The `base` role disables SSH **password** auth during hardening, so make sure
> key login works **before** you provision — otherwise you'll lock yourself out.

---

## 2. Configure `.env`

From the repo root:

```bash
cp .env.example .env
$EDITOR .env
```

Set, for the netcup path:

```dotenv
# Leave HCLOUD_TOKEN empty — not used for netcup.
HCLOUD_TOKEN=

# Your netcup VPS public IP:
SERVER_IP=<SERVER_IP>

# Your admin IP for SSH + kube-API. Leave EMPTY to auto-detect your current
# public IP at run time. See the dynamic-IP warning in step 6.
ADMIN_IP=

# Only if your GitHub repos are private:
GITHUB_ORG=your-org
GITHUB_TOKEN=<fine-grained PAT with repo read>

# If your SSH key isn't ~/.ssh/id_ed25519.pub:
#SSH_PUBLIC_KEY_FILE=/home/you/.ssh/id_ed25519.pub

# Your wildcard domain (or use sslip.io while testing):
#DOMAIN=k8s.example.com
```

Repo URLs, domain, and the Let's Encrypt email are baked into git (ArgoCD
renders what's committed, not your env). If you forked, update them per
`README.md` before bootstrapping.

---

## 3. Install the toolchain

```bash
mise trust && mise install   # kubectl, helm, kubeseal, python
mise run deps                # ansible + galaxy collections into ./.venv
```

Tools are on PATH inside `mise run` tasks and mise-activated shells; otherwise
prefix with `mise x --` (e.g. `mise x -- kubectl get nodes`).

---

## 4. Provision the VPS + k3s

```bash
mise run provision-netcup
```

This one command:

- writes the Ansible inventory pointing at `SERVER_IP`,
- resolves your admin IP (auto-detected if `ADMIN_IP` empty),
- hardens the OS (fail2ban, unattended-upgrades, disables SSH password auth,
  sysctl for k8s),
- configures the **host firewall (ufw)**: 80/443 open to the world, SSH (22) and
  kube-API (6443) allowed **only from your admin IP**,
- installs k3s (traefik disabled; servicelb + local-path kept),
- fetches `./kubeconfig` pointed at the node's public IP.

Verify:

```bash
mise x -- kubectl get nodes   # → one node, STATUS Ready
```

> Because ufw enables **default-deny incoming**, only ingress (80/443) is
> publicly reachable. NodePorts are unreachable by design — everything goes
> through ingress-nginx.

---

## 5. DNS

Create a wildcard `A` record pointing at the VPS:

```
*.k8s.example.com   A   <SERVER_IP>
```

No domain yet? Use `<name>.<SERVER_IP>.sslip.io` as hostnames and keep the
`letsencrypt-staging` issuer while testing (prod certs on sslip.io hit shared
rate limits). Swap to real DNS + `letsencrypt-prod` later.

---

## 6. Bootstrap ArgoCD (GitOps takes over)

```bash
mise run bootstrap
```

Installs ArgoCD once, creates the `grafana-admin` secret (**password is
printed — save it**), and applies `bootstrap/root-app.yaml`. From here git is
the only interface: ArgoCD syncs `platform/app-of-apps/` in ordered waves
(ArgoCD + ingress + sealed-secrets → cert-manager → issuers → monitoring →
logging → projects).

Watch progress:

```bash
mise x -- kubectl get applications -n argocd -w
```

**Immediately after `sealed-secrets` shows Synced**, back up its key:

```bash
mise run backup-sealing-key   # store master.key in a password manager, then delete it
```

Without that key, every committed SealedSecret is unrecoverable after a rebuild.

---

## 7. Verify end-to-end

1. All Applications in the ArgoCD UI are **Synced / Healthy**.
2. `https://argocd.<domain>` and `https://grafana.<domain>` serve valid Let's
   Encrypt certs (once DNS resolves and you're on `letsencrypt-prod`).
3. Grafana: dashboards show node/pod metrics; **Explore → Loki** →
   `{namespace="argocd"}` returns logs.
4. Demo app answers: `curl https://demo.<domain>`.
5. `free -m` on the node shows ≥ 2.5 GB available.

ArgoCD UI without DNS: `mise x -- kubectl port-forward -n argocd svc/argocd-server 8080:80`
then open `http://localhost:8080` (user `admin`, initial password printed by the
bootstrap script).

---

## netcup-specific notes

### ⚠ Dynamic IP = lockout risk

Unlike Hetzner, netcup has **no cloud firewall API** to unlock yourself
remotely. If your admin IP rotates (home ISP), ufw will reject your SSH and
kubectl. To recover:

1. Open the **netcup web console (VNC)** in the CCP — this bypasses ufw.
2. Log in and either add your new IP or temporarily disable ufw:
   ```bash
   ufw allow from <new-ip> to any port 22 proto tcp
   ufw allow from <new-ip> to any port 6443 proto tcp
   ```
3. Then from your machine re-sync the firewall cleanly:
   ```bash
   mise run netcup-firewall   # re-allowlists your current detected IP
   ```

A **static IP** (or a jump host / VPN with a fixed IP) avoids this entirely.

### Re-running pieces

| Task | Command |
|---|---|
| Re-apply host firewall with current IP | `mise run netcup-firewall` |
| Reconfigure node + install/upgrade k3s only | `mise run k3s` |
| Re-fetch kubeconfig | `mise run kubeconfig` |
| Full re-provision (idempotent) | `mise run provision-netcup` |

### Backups / disaster recovery

netcup has no equivalent to Hetzner snapshots via API. Options:

- Take manual VPS snapshots in the netcup CCP during quiet hours.
- Primary strategy stays **rebuild from git** (~30 min): re-run
  `mise run provision-netcup`, restore the sealed-secrets `master.key`
  **before** bootstrap, then `mise run bootstrap` and update DNS.

`local-path` PVC data (Grafana history, Loki logs) is best-effort and dies with
the disk — keep anything irreplaceable in an external DB or object storage.

---

For platform details, adding projects, and day-2 operations, see the main
[`README.md`](../README.md).
