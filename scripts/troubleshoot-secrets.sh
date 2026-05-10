#!/usr/bin/env bash
# Read-only diagnostics for the Vault → ESO → Secret → Reloader chain.
# Prints state; does NOT modify anything.
#
# Usage:  bash scripts/troubleshoot-secrets.sh
#
# Requires:  cluster access (kubectl), the `infra` and `argocd` namespaces.

set -euo pipefail

NS_INFRA="${NS_INFRA:-infra}"
NS_ARGOCD="${NS_ARGOCD:-argocd}"

bold=$(printf '\033[1m'); reset=$(printf '\033[0m')
hdr() { printf "\n%s== %s ==%s\n" "$bold" "$*" "$reset"; }

hdr "Vault status"
kubectl exec -n "$NS_INFRA" vault-0 -- vault status || true

hdr "Vault auto-unseal CronJob"
kubectl -n "$NS_INFRA" get cronjob vault-auto-unseal -o wide || true
kubectl -n "$NS_INFRA" get jobs --sort-by=.status.startTime \
  -l job-name 2>/dev/null | tail -5 || true

hdr "ClusterSecretStore"
kubectl get clustersecretstore vault -o wide || true

hdr "ExternalSecrets ($NS_INFRA)"
kubectl -n "$NS_INFRA" get externalsecret -o wide || true

hdr "ExternalSecrets ($NS_ARGOCD)"
kubectl -n "$NS_ARGOCD" get externalsecret -o wide || true

hdr "Synced K8s Secrets"
for ns_secret in "$NS_INFRA/server-secret" "$NS_INFRA/grim-app-secret" \
                 "$NS_ARGOCD/argocd-redis" "$NS_ARGOCD/argocd-secret"; do
  ns="${ns_secret%%/*}"; name="${ns_secret##*/}"
  rv=$(kubectl -n "$ns" get secret "$name" \
       -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "-")
  printf "  %-30s  rv=%s\n" "$ns_secret" "$rv"
done

hdr "Reloader"
kubectl -n "$NS_INFRA" get deploy -l app.kubernetes.io/name=reloader -o wide || true
kubectl -n "$NS_INFRA" logs deploy/reloader-reloader --tail=20 2>/dev/null \
  | grep -E 'grim-app|reloaded|skip' || \
  printf "  (no reloader output for grim-app)\n"

hdr "grim-app rollout"
kubectl -n "$NS_INFRA" rollout status deployment grim-app --timeout=5s || true
kubectl -n "$NS_INFRA" rollout history deployment grim-app | tail -5 || true

hdr "ArgoCD Application"
kubectl -n "$NS_ARGOCD" get application grim-k8s \
  -o jsonpath='{.status.sync.status}{"\t"}{.status.health.status}{"\n"}' \
  2>/dev/null || true

cat <<'EOF'

Next steps if something looks wrong:

  Force ESO refresh:
    kubectl -n infra annotate externalsecret grim-app-secret \
      force-sync="$(date +%s)" --overwrite

  Manual rollout:
    kubectl -n infra rollout restart deployment grim-app

  Manual unseal:
    UNSEAL_KEY=$(kubectl get secret -n infra vault-bootstrap-secret \
      -o jsonpath='{.data.VAULT_UNSEAL_KEY}' | base64 -d)
    kubectl exec -n infra vault-0 -- vault operator unseal "$UNSEAL_KEY"
EOF
