# Refactor summary

> **Superseded by the 2026-05-11 VSO migration.** The directory names
> `external-secrets/` and `reloader/` referenced below no longer exist —
> they were removed when the repo switched from ESO + Stakater Reloader to
> the HashiCorp Vault Secrets Operator. Kept for historical context only.

This document records the cleanup pass that introduced `docs/` and `scripts/`.
No runtime behavior changed — confirmed by a byte-identical
`kubectl kustomize --enable-helm` render before and after.

## Renamed

Files renamed via `git mv` so the filename describes the kind of resource it
contains.

| Before                                  | After                                       |
|------------------------------------------|---------------------------------------------|
| `argocd/secrets.yaml`                    | `argocd/external-secrets.yaml`              |
| `external-secrets/server-secret.yaml`    | `external-secrets/external-secrets.yaml`    |
| `keycloak/bootstrap.yaml`                | `keycloak/bootstrap-job.yaml`               |
| `vault/auto-unseal.yaml`                 | `vault/auto-unseal-cronjob.yaml`            |
| `redis/smoke-test.yaml`                  | `redis/smoke-test-job.yaml`                 |
| `postgres/init.yaml`                     | `postgres/init-configmap.yaml`              |

Each component's `kustomization.yaml` was updated to match.

## Removed

- `argocd/patches/delete-bundled-redis.yaml` — referenced no live resource.
  ArgoCD v3.4.1 stopped shipping a bundled `argocd-redis` Deployment/Service,
  so the `$patch: delete` blocks targeted nothing and the file was already
  unreferenced from `argocd/kustomization.yaml`.
- `argocd/charts/` from `.gitignore` — `argocd/` is not a Helm chart in this
  repo. Stale entry.

## Added

- `docs/architecture.md` — component map, namespaces, sync waves, bootstrap order.
- `docs/secret-refresh-flow.md` — Vault → ESO → Secret → Reloader → Pod.
- `docs/troubleshooting.md` — read-only diagnostic commands.
- `docs/refactor-summary.md` — this file.
- `scripts/validate.sh` — local pre-sync checks (kustomize render, optional
  yamllint/kubeconform).
- `scripts/troubleshoot-secrets.sh` — read-only kubectl helpers for ESO + Reloader.

## Preserved (intentionally)

- Top-level flat layout: `argocd/`, `cert-manager/`, `external-secrets/`,
  `grim-app/`, `ingress-nginx/`, `keycloak/`, `minio/`, `postgres/`, `redis/`,
  `reloader/`, `vault/`.  No `apps/` vs `platform/` split — chosen for lower
  churn at this repo size.
- ArgoCD `path: .` for the self-managed `grim-k8s` Application.
- Inline patches inside `argocd/kustomization.yaml` (replicas: 0 for
  AppSet/Dex/Notifications, resource caps).
- `redis/smoke-test-job.yaml` — re-runs every ArgoCD sync via
  `Force=true,Replace=true`. Useful as a continuous health probe.
- All selector labels (`app: <name>`).  Changing them would break running
  pods; the cleanup pass deliberately avoided this.

## Manual review

- The smoke-test Job rebuilds on every sync. If it becomes noisy, consider
  removing it in a follow-up. Behavior is unchanged here.
- Per-component `app.kubernetes.io/component` labels are not added. They'd
  be safe via Kustomize `labels: includeSelectors: false`, but the value is
  marginal at this repo size.

## Validation

```sh
bash scripts/validate.sh
```

If kubeconform and yamllint are installed, the script also runs them. Neither
is required.

## Sync after merge

ArgoCD's self-managed Application points at `path: .`. After the commit
lands on `main`, ArgoCD picks it up on the next refresh (default 3 min).
Force immediately:

```sh
kubectl -n argocd annotate application grim-k8s \
  argocd.argoproj.io/refresh=hard --overwrite
```
