#!/usr/bin/env bash
# Cluster pre/post-sync health check. Requires kubectl access to the cluster.
#
# Usage: bash scripts/check-cluster-sync.sh

set -euo pipefail

bold=$(printf '\033[1m'); red=$(printf '\033[31m'); green=$(printf '\033[32m'); yellow=$(printf '\033[33m'); reset=$(printf '\033[0m')
ok()   { printf "%s[ OK ]%s %s\n"   "$green" "$reset" "$*"; }
warn() { printf "%s[WARN]%s %s\n"   "$yellow" "$reset" "$*"; }
fail() { printf "%s[FAIL]%s %s\n"   "$red"   "$reset" "$*"; }
hdr()  { printf "\n%s== %s ==%s\n" "$bold"  "$*" "$reset"; }

ERRORS=0

APP_NAMESPACE=${APP_NAMESPACE:-argocd}
APP_NAME=${APP_NAME:-grim-k8s}
WORKLOAD_NAMESPACE=${WORKLOAD_NAMESPACE:-infra}

check_app() {
  hdr "argocd application"

  local sync health phase message
  sync=$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.sync.status}')
  health=$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.health.status}')
  phase=$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.operationState.phase}')
  message=$(kubectl -n "$APP_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.operationState.message}')

  if [[ "$sync" == "Synced" && "$health" == "Healthy" && "$phase" == "Succeeded" ]]; then
    ok "$APP_NAME sync=$sync health=$health phase=$phase"
  else
    fail "$APP_NAME sync=$sync health=$health phase=$phase message=$message"
    ERRORS=$((ERRORS+1))
  fi
}

check_vault_static_secrets() {
  hdr "vault static secrets"

  local rows name conditions secret_synced healthy ready destination
  rows=$(kubectl -n "$WORKLOAD_NAMESPACE" get vaultstaticsecret \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.destination.name}{"\t"}{range .status.conditions[*]}{.type}={.status};{end}{"\n"}{end}')

  if [[ -z "$rows" ]]; then
    fail "no VaultStaticSecret resources found in $WORKLOAD_NAMESPACE"
    ERRORS=$((ERRORS+1))
    return
  fi

  while IFS=$'\t' read -r name destination conditions; do
    secret_synced=$(grep -o 'SecretSynced=True' <<<"$conditions" || true)
    healthy=$(grep -o 'Healthy=True' <<<"$conditions" || true)
    ready=$(grep -o 'Ready=True' <<<"$conditions" || true)

    if [[ -n "$secret_synced" && -n "$healthy" && -n "$ready" ]]; then
      ok "$name"
    elif [[ -n "$healthy" && -n "$ready" ]] \
      && kubectl -n "$WORKLOAD_NAMESPACE" get secret "${destination:-$name}" >/dev/null 2>&1; then
      warn "$name has stale SecretSynced condition but Ready/Healthy are true and Secret ${destination:-$name} exists"
    else
      fail "$name conditions=$conditions"
      ERRORS=$((ERRORS+1))
    fi
  done <<<"$rows"
}

check_stuck_hooks() {
  hdr "hook jobs"

  local terminating failed
  terminating=$(kubectl -n "$WORKLOAD_NAMESPACE" get job \
    -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' || true)
  failed=$(kubectl -n "$WORKLOAD_NAMESPACE" get job \
    -l app.kubernetes.io/managed-by=argocd \
    -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{" failed="}{.status.failed}{"\n"}{end}' || true)

  if [[ -z "$terminating" && -z "$failed" ]]; then
    ok "no stuck terminating or failed Argo-managed jobs"
  else
    [[ -z "$terminating" ]] || printf "%s\n" "$terminating" | sed 's/^/    terminating: /'
    [[ -z "$failed" ]] || printf "%s\n" "$failed" | sed 's/^/    failed: /'
    ERRORS=$((ERRORS+1))
  fi
}

check_app
check_vault_static_secrets
check_stuck_hooks

hdr "summary"
if [[ "$ERRORS" -eq 0 ]]; then
  ok "cluster is ready for GitOps sync"
  exit 0
fi

fail "$ERRORS check(s) failed"
exit 1
