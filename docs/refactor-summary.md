# Refactor summary

Cumulative record of structural changes since the repo was first laid out.
No runtime behavior changes were introduced by renames; behavior changes
came from the VSO migration (below) and the issue fixes captured in
[issue.md](issue.md).

## 2026-05-11 — VSO migration

Switched cluster secret sync from **External Secrets Operator (ESO) +
Stakater Reloader** to the **HashiCorp Vault Secrets Operator (VSO)**.

### Removed

- `external-secrets/` directory — replaced by `vault-secrets-operator/`.
- `reloader/` directory — replaced by VSO's built-in `rolloutRestartTargets`.
- All `ExternalSecret`, `SecretStore`, `ClusterSecretStore` resources.
- All Reloader annotations on Deployments/StatefulSets.

### Added

- `vault-secrets-operator/` — `ServiceAccount`, `VaultConnection`,
  `VaultAuth` (kubernetes method), and per-app `VaultStaticSecret`
  resources with `refreshAfter: 30s` and `rolloutRestartTargets`.
- `argocd/applications/vault-secrets-operator.yaml` — standalone ArgoCD
  Application installing the VSO Helm chart, annotated
  `argocd.argoproj.io/sync-wave: "-1"` so it lands before every business
  Application.
- `argocd/vault-secrets.yaml` — ArgoCD-namespace `VaultStaticSecret`s
  (`argocd-redis`, `argocd-keycloak-oidc`) with VSO transformation
  templates and labels for ArgoCD ownership.
- `vault/auth-config-job.yaml` — Job that configures Vault's Kubernetes
  auth role + OIDC auth method + `keycloak` role + `grim-k8s-read`
  policy (idempotent; re-runs on every sync).

### Why each piece

| Choice | Reason |
|--------|--------|
| `destination.overwrite: true` on every `VaultStaticSecret` | VSO refused to take over Secrets pre-created during bootstrap. |
| `ignoreDifferences` on `Secret /data` in `argocd/applications/grim-k8s.yaml` | VSO mutates `/data` on every sync; without this, ArgoCD would flag every refreshed Secret as `OutOfSync`. |
| Sync-wave `-1` on the VSO Application | VSO CRDs must exist before any `VaultStaticSecret` in the rest of the repo. |

See [secret-refresh-flow.md](secret-refresh-flow.md) for the data path
and [deployment-sequence.md](deployment-sequence.md) for the full
bootstrap ordering.

## 2026-05-11 — Issue fixes baked in

The 10 issues documented in [issue.md](issue.md) are all closed in YAML.
Concretely:

- `keycloak/deployment.yaml` — `KC_HEALTH_ENABLED=true`, probes on port
  `9000`.
- `keycloak/bootstrap-job.yaml` — broadened MinIO redirect URIs (console
  + S3 hosts), idempotent client upsert so ArgoCD/MinIO/Vault OIDC
  clients stay in sync with the Secret.
- `vault-secrets-operator/{server,grim-app}-secret.yaml` —
  `destination.overwrite: true`.
- `argocd/vault-secrets.yaml` — `argocd-keycloak-oidc` Secret gets
  `app.kubernetes.io/part-of: argocd` labels and `overwrite: true`.
- `vault/auth-config-job.yaml` — configures the OIDC role/policy/tune
  settings that used to be applied manually.

## 2026-05-12 — cert-manager removed, Cloudflare Origin Certs

Removed `cert-manager/` and the `letsencrypt` ClusterIssuer entirely.
Public TLS is now handled by Cloudflare: the edge terminates with
Cloudflare's own cert, and the cluster presents a Cloudflare Origin
Certificate (15-year validity) to the proxy. Each ingress now references
a manually-created `kubernetes.io/tls` Secret instead of a cert-manager
issuer annotation.

### Why

- HTTP-01 ACME breaks when hosts are orange-clouded — Cloudflare
  intercepts `/.well-known/acme-challenge/...` and the LE rate limit
  closes in (issue #6 in [issue.md](issue.md)).
- Origin Certs are free, valid 15 years, and trusted by Cloudflare in
  Full (Strict) SSL mode — no operator, no renewal automation.

### What changed

- Deleted `cert-manager/` directory and the root kustomization entry.
- Stripped `cert-manager.io/cluster-issuer` annotations from all 5
  ingresses (`grim-app`, `argocd`, `minio`, `keycloak`, `vault`).
- Added [cloudflare-proxy.md](cloudflare-proxy.md) covering the proxy
  setup, Origin Cert generation, and Secret install.

## Earlier renames (historical)

Filenames were normalized so each describes the resource kind it
contains. Component `kustomization.yaml` files were updated to match.

| Before | After |
|--------|-------|
| `keycloak/bootstrap.yaml` | `keycloak/bootstrap-job.yaml` |
| `vault/auto-unseal.yaml` | `vault/auto-unseal-cronjob.yaml` |
| `redis/smoke-test.yaml` | `redis/smoke-test-job.yaml` |
| `postgres/init.yaml` | `postgres/init-configmap.yaml` |

(The `argocd/secrets.yaml` → `argocd/external-secrets.yaml` and
`external-secrets/` renames from the pre-VSO refactor are no longer
relevant — those files were deleted in the VSO migration.)

## Current directory layout

Top-level, flat — no `apps/` vs `platform/` split:

```
argocd/                 docs/                 grim-app/
ingress-nginx/          keycloak/             minio/
postgres/               redis/                scripts/
vault/                  vault-secrets-operator/
```

ArgoCD's self-managed `grim-k8s` Application points at `path: .` so the
root `kustomization.yaml` defines what's in cluster scope.

## Scripts

- `scripts/validate.sh` — local pre-sync checks: `kubectl kustomize
  --enable-helm`, optional `yamllint`/`kubeconform`.
- `scripts/troubleshoot-secrets.sh` — read-only diagnostics for the
  Vault → VSO → Secret → rollout chain.

## Validation

```sh
bash scripts/validate.sh
```

`yamllint` and `kubeconform` are picked up if installed; neither is
required.

## Sync after merge

ArgoCD's self-managed Application points at `path: .`. After the commit
lands on `main`, ArgoCD picks it up on the next refresh (default 3 min).
Force immediately:

```sh
kubectl -n argocd annotate application grim-k8s \
  argocd.argoproj.io/refresh=hard --overwrite
```
