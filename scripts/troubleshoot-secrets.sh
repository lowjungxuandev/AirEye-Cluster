#!/usr/bin/env bash
# Read-only diagnostics for the Vault -> VSO -> Secret -> rollout chain.
# Prints state; does NOT modify anything.
#
# Usage:  bash scripts/troubleshoot-secrets.sh
#
# Requires:  cluster access (kubectl), the `infra`, `argocd` and
#            `vault-secrets-operator` namespaces.

set -euo pipefail

NS_INFRA="${NS_INFRA:-infra}"
NS_ARGOCD="${NS_ARGOCD:-argocd}"
NS_VSO="${NS_VSO:-vault-secrets-operator}"

bold=$(printf '\033[1m'); reset=$(printf '\033[0m')
hdr() { printf "\n%s== %s ==%s\n" "$bold" "$*" "$reset"; }

hdr "Vault status"
kubectl exec -n "$NS_INFRA" vault-0 -- vault status || true

hdr "Vault auto-unseal CronJob"
kubectl -n "$NS_INFRA" get cronjob vault-auto-unseal -o wide || true
kubectl -n "$NS_INFRA" get jobs --sort-by=.status.startTime \
  -l job-name 2>/dev/null | tail -5 || true

hdr "VSO operator"
kubectl -n "$NS_VSO" get deploy,pods -o wide || true

hdr "VaultConnection / VaultAuth"
kubectl -n "$NS_INFRA"  get vaultconnection,vaultauth -o wide || true
kubectl -n "$NS_ARGOCD" get vaultconnection,vaultauth -o wide || true

hdr "VaultStaticSecrets ($NS_INFRA)"
kubectl -n "$NS_INFRA" get vaultstaticsecret -o wide || true

hdr "VaultStaticSecrets ($NS_ARGOCD)"
kubectl -n "$NS_ARGOCD" get vaultstaticsecret -o wide || true

hdr "Synced K8s Secrets"
for ns_secret in "$NS_INFRA/server-secret" "$NS_INFRA/grim-app-secret" \
                 "$NS_ARGOCD/argocd-redis" "$NS_ARGOCD/argocd-keycloak-oidc"; do
  ns="${ns_secret%%/*}"; name="${ns_secret##*/}"
  rv=$(kubectl -n "$ns" get secret "$name" \
       -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "-")
  printf "  %-40s  rv=%s\n" "$ns_secret" "$rv"
done

hdr "grim-app rollout"
kubectl -n "$NS_INFRA" rollout status deployment grim-app --timeout=5s || true
kubectl -n "$NS_INFRA" rollout history deployment grim-app | tail -5 || true

hdr "ArgoCD Applications"
kubectl -n "$NS_ARGOCD" get application -o wide || true

cat <<'EOF'

Next steps if something looks wrong:

  Force VSO refresh:
    kubectl -n infra annotate vaultstaticsecret grim-app-secret \
      vso.hashicorp.com/force-sync="$(date +%s)" --overwrite

  Manual rollout:
    kubectl -n infra rollout restart deployment grim-app

  Manual unseal:
    UNSEAL_KEY=$(kubectl get secret -n infra vault-bootstrap-secret \
      -o jsonpath='{.data.VAULT_UNSEAL_KEY}' | base64 -d)
    kubectl exec -n infra vault-0 -- vault operator unseal "$UNSEAL_KEY"
EOF
