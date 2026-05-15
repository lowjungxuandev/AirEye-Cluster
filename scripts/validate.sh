#!/usr/bin/env bash
# Local pre-sync validation. Does NOT require cluster access.
#
# Runs:
#   1. kustomize render of every entrypoint (root, argocd, argocd/applications)
#   2. yamllint (if installed)
#   3. kubeconform (if installed)
#
# Usage:  bash scripts/validate.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

bold=$(printf '\033[1m'); red=$(printf '\033[31m'); green=$(printf '\033[32m'); reset=$(printf '\033[0m')
ok()   { printf "%s[ OK ]%s %s\n"   "$green" "$reset" "$*"; }
fail() { printf "%s[FAIL]%s %s\n"   "$red"   "$reset" "$*"; }
hdr()  { printf "\n%s== %s ==%s\n" "$bold"  "$*" "$reset"; }

KUSTOMIZE_ENTRYPOINTS=(
  "."
  "argocd"
  "argocd/applications"
)

ERRORS=0
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT

hdr "kustomize render"
for ep in "${KUSTOMIZE_ENTRYPOINTS[@]}"; do
  out="$RENDER_DIR/$(echo "$ep" | tr / _).yaml"
  if kubectl kustomize --enable-helm "$ep" > "$out" 2>"$out.err"; then
    lines=$(wc -l <"$out" | tr -d ' ')
    ok "$ep  ($lines lines)"
  else
    fail "$ep"
    sed 's/^/    /' "$out.err"
    ERRORS=$((ERRORS+1))
  fi
done

hdr "yamllint"
if command -v yamllint >/dev/null 2>&1; then
  # Skip rendered Helm charts (vendored) and rendered output.
  mapfile -t yaml_files < <(find . -path ./.git -prune -o \( -name '*.yaml' -o -name '*.yml' \) -type f -print)
  if yamllint -d "{extends: relaxed, rules: {line-length: disable}}" \
       "${yaml_files[@]}"; then
    ok "yamllint clean"
  else
    fail "yamllint reported issues"
    ERRORS=$((ERRORS+1))
  fi
else
  printf "    skipped (yamllint not installed)\n"
fi

hdr "kubeconform"
if command -v kubeconform >/dev/null 2>&1; then
  for f in "$RENDER_DIR"/*.yaml; do
    if kubeconform -strict -ignore-missing-schemas -summary "$f"; then
      ok "$(basename "$f")"
    else
      fail "$(basename "$f")"
      ERRORS=$((ERRORS+1))
    fi
  done
else
  printf "    skipped (kubeconform not installed — install: https://github.com/yannh/kubeconform)\n"
fi

hdr "summary"
if [[ "$ERRORS" -eq 0 ]]; then
  ok "all checks passed"
  exit 0
else
  fail "$ERRORS check(s) failed"
  exit 1
fi
