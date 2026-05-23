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
WORKLOAD_NAMESPACE=${WORKLOAD_NAMESPACE:-infra}
# Comma-separated Application names in APP_NAMESPACE (default: all managed apps).
APP_NAMES=${APP_NAMES:-aireye-cluster,langfuse,vault,vault-secrets-operator}

check_applications() {
  hdr "argocd applications"

  local name sync health phase message revision
  IFS=',' read -ra names <<<"$APP_NAMES"
  for name in "${names[@]}"; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -n "$name" ]] || continue

    if ! kubectl -n "$APP_NAMESPACE" get application "$name" >/dev/null 2>&1; then
      fail "missing Application/$name in $APP_NAMESPACE"
      ERRORS=$((ERRORS+1))
      continue
    fi

    sync=$(kubectl -n "$APP_NAMESPACE" get application "$name" -o jsonpath='{.status.sync.status}')
    health=$(kubectl -n "$APP_NAMESPACE" get application "$name" -o jsonpath='{.status.health.status}')
    phase=$(kubectl -n "$APP_NAMESPACE" get application "$name" -o jsonpath='{.status.operationState.phase}')
    message=$(kubectl -n "$APP_NAMESPACE" get application "$name" -o jsonpath='{.status.operationState.message}')
    revision=$(kubectl -n "$APP_NAMESPACE" get application "$name" -o jsonpath='{.status.sync.revision}')

    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      ok "$name sync=$sync health=$health phase=${phase:-n/a} rev=${revision:-helm}"
    else
      fail "$name sync=$sync health=$health phase=${phase:-n/a} message=$message"
      ERRORS=$((ERRORS+1))
    fi
  done
}

check_orphan_applications() {
  hdr "orphan applications"

  local orphans
  orphans=$(kubectl get applications -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
    | grep -v "^${APP_NAMESPACE}/" || true)

  if [[ -z "$orphans" ]]; then
    ok "no Applications outside $APP_NAMESPACE"
    return
  fi

  while IFS= read -r orphan; do
    [[ -n "$orphan" ]] || continue
    fail "orphan Application/$orphan (delete or move under $APP_NAMESPACE)"
    ERRORS=$((ERRORS+1))
  done <<<"$orphans"
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

check_applications
check_orphan_applications
check_vault_static_secrets
check_stuck_hooks

hdr "summary"
if [[ "$ERRORS" -eq 0 ]]; then
  ok "cluster is ready for GitOps sync"
  exit 0
fi

fail "$ERRORS check(s) failed"
exit 1
