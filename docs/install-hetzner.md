---
type: Guide
title: Installing on Hetzner Cloud
description: Step-by-step install of the k3s + ArgoCD platform on a new Hetzner Cloud server, from API token to a running notes app.
tags: [install, hetzner, k3s, argocd]
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-16T14:00:00Z }
---

# Installing on Hetzner Cloud

This guide brings up the full platform on a **new Hetzner Cloud server**. The
Ansible playbook creates the server, the cloud firewall, and the SSH key
through the Hetzner API. Then it hardens the OS and installs k3s. After that,
ArgoCD deploys everything else from git.

For an existing VPS (netcup or other), use
[`install-netcup.md`](install-netcup.md) instead.

Time: about 30 minutes.

---

## 0. Prerequisites

On your **local machine**:

- [mise](https://mise.jdx.dev) (`curl https://mise.run | sh`).
- An SSH key pair. Check with `ls ~/.ssh/id_ed25519.pub`. If it is missing,
  create one:
  ```bash
  ssh-keygen -t ed25519 -C "k3s-admin"
  ```
- This repo, cloned.

Other requirements:

- A **Hetzner Cloud** account.
- A **domain** where you can create one wildcard `A` record. Without a
  domain, use `sslip.io` (see step 5).

---

## 1. Create a Hetzner project and API token

1. Open the [Hetzner Console](https://console.hetzner.com) and create a
   project, for example `k8s`.
2. In the project, go to **Security → API tokens → Generate API token**.
3. Select **Read & Write**. The playbook creates the server, the firewall,
   and the SSH key, so it needs write access.
4. Copy the token. Hetzner shows it only once.

> The token gives full control of the project. Keep it in `.env` only. Git
> ignores that file.

---

## 2. Configure `.env`

From the repo root:

```bash
cp .env.example .env
$EDITOR .env
```

Set these values for the Hetzner path:

```dotenv
# Required:
HCLOUD_TOKEN=<your API token>

# Leave SERVER_IP empty. The playbook gets the IP from the Hetzner API.
SERVER_IP=

# Admin IP for SSH (22) and the Kubernetes API (6443). Leave EMPTY to use
# your current public IP, detected when the playbook runs.
ADMIN_IP=

# Only if your GitHub repos are private:
GITHUB_ORG=dgmmarin
GITHUB_TOKEN=
```

Optional values, with their defaults:

| Variable | Default | Notes |
| --- | --- | --- |
| `HCLOUD_SERVER_NAME` | `k3s-1` | Server name in the Hetzner project |
| `HCLOUD_SERVER_TYPE` | `cpx31` | 4 vCPU, 8 GB RAM, 160 GB disk. Do not use a smaller type: Prometheus, Loki, and Grafana need the memory. |
| `HCLOUD_LOCATION` | `nbg1` | `nbg1`, `fsn1`, or `hel1` |
| `HCLOUD_IMAGE` | `ubuntu-24.04` | |
| `SSH_PUBLIC_KEY_FILE` | `~/.ssh/id_ed25519.pub` | Public key that the playbook uploads |
| `K3S_VERSION` | `v1.36.2+k3s1` | |
| `GRAFANA_ADMIN_PASSWORD` | random | The bootstrap script prints it once |

If Hetzner does not offer `cpx31` in your location, set
`HCLOUD_SERVER_TYPE` to a type with at least 4 vCPU and 8 GB RAM. The
Hetzner Console shows the types for each location.

The repo URLs, the domain (`k8s.bitulzero.ro`), and the Let's Encrypt
e-mail are in git, not in `.env`. ArgoCD reads what is committed. If you
forked the repo, change them first (see `README.md`, section "Configure").

---

## 3. Install the tools

```bash
mise trust && mise install   # kubectl, helm, kubeseal, python
mise run deps                # Ansible, the hcloud library, and the collections, in ./.venv
```

The tools are on PATH inside `mise run` tasks and in shells where mise is
active. In other shells, start a command with `mise x --`, for example
`mise x -- kubectl get nodes`.

---

## 4. Create the server and install k3s

```bash
mise run provision
```

This command runs `ansible/playbooks/site.yml`. It does these steps:

1. It finds your public IP, if `ADMIN_IP` is empty.
2. It uploads your SSH public key to Hetzner as `k3s-admin`.
3. It creates the cloud firewall `k3s-firewall`:
   - ports 80 and 443, and ICMP: open to everyone
   - port 22 (SSH) and port 6443 (Kubernetes API): open only to your admin IP
4. It creates and starts the server, with IPv4 and IPv6, and attaches the
   SSH key and the firewall.
5. It writes `ansible/inventory/hosts.yml` and waits until SSH is available.
6. It hardens the OS:
   - It upgrades all packages.
   - It installs fail2ban and turns on automatic security updates.
   - It turns off SSH password login.
   - It sets the inotify limits that Kubernetes needs.
7. It installs k3s. Traefik is off, because ArgoCD installs ingress-nginx.
8. It writes `./kubeconfig`, which points to the server's public IP.

At the end, the playbook prints the server IP. Write it down.

Check the result:

```bash
mise x -- kubectl get nodes   # one node, STATUS Ready
```

You can run `mise run provision` again at any time. It changes only what is
different from the expected state.

---

## 5. DNS

Create one wildcard `A` record that points to the server IP:

```
*.k8s.bitulzero.ro   A   <server IP>
```

This record covers every service: `argocd.`, `grafana.`, `demo.`, and
`notes.`.

If you have no domain yet, use `<name>.<server IP>.sslip.io` as host names,
and keep the `letsencrypt-staging` issuer. Let's Encrypt production has
shared rate limits for `sslip.io`. Change to real DNS and
`letsencrypt-prod` later.

---

## 6. Bootstrap ArgoCD

```bash
mise run bootstrap
```

The script does these steps:

1. It installs ArgoCD with Helm.
2. It creates the `grafana-admin` Secret and prints the Grafana password.
   **Save it now.** The script does not show it again.
3. It applies `bootstrap/root-app.yaml`.
4. It prints the ArgoCD `admin` password.

After this, git is the only way to change the cluster. ArgoCD syncs
`platform/app-of-apps/` in waves:

| Wave | Applications |
| --- | --- |
| 0 | ArgoCD, ingress-nginx, sealed-secrets, Prometheus CRDs, `Note` CRD |
| 1 | cert-manager, secrets |
| 2 | Let's Encrypt cluster issuers |
| 3 | monitoring, Loki |
| 4 | Alloy (log collector) |
| 5 | projects (the ApplicationSet that deploys `demo-app` and `notes`) |

Watch the progress:

```bash
mise x -- kubectl get applications -n argocd -w
```

**When `sealed-secrets` shows Synced, back up its key immediately:**

```bash
mise run backup-sealing-key   # store master.key in a password manager, then delete the file
```

Without this key, you cannot decrypt any committed SealedSecret after a
rebuild.

---

## 7. Turn on the notes app

ArgoCD deploys the notes app from
[dgmmarin/notes](https://github.com/dgmmarin/notes), but nginx refuses
every request (HTTP 503) until the app has a login. Create the login from
the notes repo:

```bash
cd ../notes
cp .env.example .env              # set NOTES_USER and NOTES_PASSWORD
KUBECONFIG=../k8s.cluster/kubeconfig mise run seal-auth
git add deploy && git commit -m "Seal notes login" && git push
```

ArgoCD checks the repo every 3 minutes. Then
`https://notes.k8s.bitulzero.ro` asks for the login. The first
certificate comes from `letsencrypt-staging`, so the browser shows a
warning. When the site works, change `deploy/ingress.yaml` to
`letsencrypt-prod` and push.

---

## 8. Check the result

1. All Applications in the ArgoCD UI are **Synced** and **Healthy**.
2. `https://argocd.k8s.bitulzero.ro` and `https://grafana.k8s.bitulzero.ro`
   have valid Let's Encrypt certificates.
3. In Grafana, the dashboards show node and pod metrics. In
   **Explore → Loki**, the query `{namespace="argocd"}` returns logs.
4. `curl https://demo.k8s.bitulzero.ro` returns a response.
5. `https://notes.k8s.bitulzero.ro` asks for the login. After login, you can
   add a note.
6. `free -m` on the node shows 2.5 GB or more available.

To open the ArgoCD UI before DNS works:

```bash
mise x -- kubectl port-forward -n argocd svc/argocd-server 8080:80
```

Then open `http://localhost:8080` (user `admin`, password from step 6).

---

## Hetzner notes

### Dynamic IP

The firewall allows SSH and the Kubernetes API only from your admin IP. If
your IP changes, SSH and `kubectl` stop working. Run:

```bash
mise run firewall
```

This command changes the Hetzner firewall through the API, not through the
server. It works even when the server does not accept your connection.

### Run one part again

| Task | Command |
| --- | --- |
| Allow your current IP in the firewall | `mise run firewall` |
| Create or change only the server and firewall | `mise run server` |
| Configure the node and install or upgrade k3s | `mise run k3s` |
| Get the kubeconfig again | `mise run kubeconfig` |
| Full run (safe to repeat) | `mise run provision` |

### Backups and disaster recovery

The main strategy is to **rebuild from git** (about 30 minutes):

1. `mise run provision` creates a new server.
2. Restore the sealed-secrets key **before** the bootstrap:
   `kubectl apply -f master.key` (from your password manager).
3. Run `mise run bootstrap`, then change the DNS record to the new IP.

Data on `local-path` volumes (Grafana history, Loki logs, project volumes)
is lost with the disk. For point-in-time copies, take Hetzner snapshots in
the Console or with `hcloud server create-image`. Keep data that you cannot
lose in an external database or object storage.

### Delete everything

The playbook has no delete task. To stop the costs, delete these resources in
the Hetzner Console, in your project:

1. the server (`k3s-1`)
2. the firewall (`k3s-firewall`)
3. the SSH key (`k3s-admin`), if no other server uses it

Then delete the DNS record, and delete `./kubeconfig` and
`ansible/inventory/hosts.yml` on your machine.

### Problems

| Problem | Cause and fix |
| --- | --- |
| `provision` fails with an authentication error | `HCLOUD_TOKEN` is empty, wrong, or read-only. Make a Read & Write token. |
| `provision` fails on the SSH key with "already exists" or "not unique" | The same public key is already in the project under another name. Delete it in the Console, or set `SSH_PUBLIC_KEY_FILE` to a different key. |
| `provision` fails on the server type | `HCLOUD_SERVER_TYPE` is not available in `HCLOUD_LOCATION`. Choose another type or location. |
| `kubectl` times out | Your IP changed. Run `mise run firewall`. |
| A certificate stays not ready | The DNS record does not point to the server yet, or you are on `letsencrypt-staging`. Check with `dig notes.k8s.bitulzero.ro`. |
| `notes` returns 503 | The login is not sealed yet. See step 7. |

---

For platform details, adding projects, and day-2 operations, see the main
[`README.md`](../README.md).
