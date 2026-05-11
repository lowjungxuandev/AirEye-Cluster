# Secret refresh flow

How a Vault edit reaches a running pod.

```
┌────────────────────┐
│ Vault UI / CLI     │  edit secret/grim-app-secret
└──────────┬─────────┘
           │
           ▼  every 30 s  (refreshAfter)
┌─────────────────────┐
│ VaultStaticSecret   │  vault-secrets-operator/grim-app-secret.yaml
│ grim-app-secret     │
└──────────┬──────────┘
           │  VSO writes
           ▼
┌────────────────────┐
│ K8s Secret         │
│ grim-app-secret    │  same name, same namespace (infra)
└──────────┬─────────┘
           │  VSO triggers via rolloutRestartTargets
           ▼
┌────────────────────┐
│ Deployment         │  rolling restart
│ grim-app           │
└──────────┬─────────┘
           ▼
┌────────────────────┐
│ Pod (new revision) │  reads new envFrom values
└────────────────────┘
```

## Why each piece exists

- **`refreshAfter: 30s`** — bounds how stale Kubernetes can be vs. Vault.
- **`destination.create: true`** — VSO owns and overwrites the Secret.
  Manual edits to the K8s Secret are clobbered on next sync.
- **`rolloutRestartTargets`** — `envFrom` env vars are baked into the pod
  at startup. VSO triggers a rollout restart on each listed workload when
  the Secret content changes. No Reloader needed.

## ArgoCD drift

VSO mutates the `/data` field of every Secret it manages. The grim-k8s
ArgoCD Application sets `ignoreDifferences` to exclude that field so the
Application stays `Synced`. See `argocd/applications/grim-k8s.yaml`.

## Force a refresh manually

```sh
# 1. Force VSO to re-read Vault now (don't wait 30 s)
kubectl -n infra annotate vaultstaticsecret grim-app-secret \
  vso.hashicorp.com/force-sync="$(date +%s)" --overwrite

# 2. Verify the K8s Secret was updated
kubectl -n infra get vaultstaticsecret grim-app-secret
kubectl -n infra get secret grim-app-secret -o jsonpath='{.metadata.resourceVersion}'

# 3. Manual restart (only needed if rolloutRestartTargets is missing)
kubectl -n infra rollout restart deployment grim-app
kubectl -n infra rollout status  deployment grim-app
```

## What does NOT trigger a restart

- Editing the K8s Secret directly — VSO will revert it within 30 s.
- Adding a workload to a Secret without listing it in
  `rolloutRestartTargets` — VSO only restarts the workloads it knows about.
