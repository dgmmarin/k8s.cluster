#!/usr/bin/env bash
# One-time cluster bootstrap: installs ArgoCD via Helm, then applies the root
# Application. From that point on, ArgoCD manages everything (itself included)
# from git — this script is never needed again except for disaster recovery.
#
# Requirements: kubectl, helm, a reachable cluster (KUBECONFIG or ./kubeconfig).
# Optional env vars (loaded from .env automatically):
#   GITHUB_ORG + GITHUB_TOKEN  — create repo credentials for private GitHub repos
#   GRAFANA_ADMIN_PASSWORD     — Grafana admin password (random if empty)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

export KUBECONFIG="${KUBECONFIG:-$PWD/kubeconfig}"

# Keep in sync with platform/app-of-apps/argocd.yaml (targetRevision).
ARGOCD_CHART_VERSION="10.1.2"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Repo credentials template: one secret covers every repo under the org prefix.
# Later you should replace this with the SealedSecret version in platform/secrets/.
if [[ -n "${GITHUB_ORG:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  kubectl -n argocd create secret generic repo-creds-github \
    --from-literal=type=git \
    --from-literal=url="https://github.com/${GITHUB_ORG}" \
    --from-literal=username=git \
    --from-literal=password="${GITHUB_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret repo-creds-github \
    argocd.argoproj.io/secret-type=repo-creds --overwrite
  echo "==> Created repo-creds for https://github.com/${GITHUB_ORG}"
fi

echo "==> Installing ArgoCD ${ARGOCD_CHART_VERSION}"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  -f platform/argocd/values.yaml \
  --wait --timeout 10m

# Grafana admin credentials (kube-prometheus-stack expects this secret).
# Created imperatively so the monitoring stack can start on first sync;
# not managed by ArgoCD, so it is never pruned.
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  GRAFANA_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)}"
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_PASSWORD}"
  echo "==> Grafana admin password (user: admin): ${GRAFANA_PASSWORD}"
  echo "    Store it in a password manager NOW — it is not shown again."
fi

echo "==> Applying root Application (GitOps takes over from here)"
kubectl apply -f bootstrap/root-app.yaml

echo "==> ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d || true
echo
echo "==> UI: kubectl port-forward -n argocd svc/argocd-server 8080:80"
echo "    (or https://argocd.<your-domain> once DNS + cert-manager are up)"
echo
echo "==> IMPORTANT next step after sealed-secrets is Synced:"
echo "    make backup-sealing-key"
