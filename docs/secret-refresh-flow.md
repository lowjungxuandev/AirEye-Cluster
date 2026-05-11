# Secret refresh flow

How secrets get into the cluster (VSO seeding) and how a Vault edit reaches
a running pod (refresh flow). All driven by the HashiCorp **Vault Secrets
Operator (VSO)** — no External Secrets Operator, no Reloader.

## Capability 1 — VSO seeding

Two layers of resources: cluster-level (one-time) and app-level (per
application).

### Cluster-level (sync-wave `-1`)

| Resource | File | Purpose |
|----------|------|---------|
| ArgoCD `Application: vault-secrets-operator` | `argocd/applications/vault-secrets-operator.yaml` | Installs the VSO Helm chart into the `vault-secrets-operator` namespace. Annotated `argocd.argoproj.io/sync-wave: "-1"` so it lands before any business Application. |
| `VaultConnection` | `vault-secrets-operator/vault-connection.yaml` | Declares the Vault server address (`http://vault.infra.svc.cluster.local:8200`). One per cluster. |
| `VaultAuth` | `vault-secrets-operator/vault-auth.yaml` | Configures the Kubernetes auth method (`mount: kubernetes`, `role: vso-grim-k8s`), bound to the `vault-secrets-operator` ServiceAccount that VSO uses to authenticate against Vault. |
| `ServiceAccount: vault-secrets-operator` | `vault-secrets-operator/service-account.yaml` | The SA referenced by `VaultAuth.spec.kubernetes.serviceAccount`. |

### App-level (same wave as the workload)

| Resource | File | Purpose |
|----------|------|---------|
| `VaultStaticSecret` | `vault-secrets-operator/grim-app-secret.yaml`, `server-secret.yaml` | Maps a Vault KV path → a k8s Secret. Sets `refreshAfter: 30s` and `rolloutRestartTargets`. |
| `Deployment` envFrom | `grim-app/deployment.yaml` | App reads the k8s Secret VSO writes via `envFrom.secretRef.name`. |

The `VaultStaticSecret` can share the same sync wave as its Deployment — if
the Pod starts before the Secret exists, Kubernetes retries automatically.

### Out of scope for kustomize

Initializing data inside Vault (`vault kv put ...`) and configuring Vault
roles/policies/auth backends are handled manually or via Terraform by the
Vault administrator. None of that lives in YAML.

## Capability 2 — pods auto-pick-up secret updates

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

### Why each piece exists

- **`refreshAfter: 30s`** — bounds how stale Kubernetes can be vs. Vault.
- **`destination.create: true` + `overwrite: true`** — VSO owns and
  overwrites the Secret. Manual edits to the K8s Secret are clobbered on
  next sync.
- **`rolloutRestartTargets`** — `envFrom` env vars are baked into the pod
  at startup. VSO triggers a rollout restart on each listed workload when
  the Secret content changes. **No Reloader needed.**

### ArgoCD drift handling

Vault edits never reach git, but VSO mutates the `/data` field of every
Secret it manages — ArgoCD would normally flag this as `OutOfSync`. The
`grim-k8s` Application sets `ignoreDifferences` to exclude `/data` on
`kind: Secret` so the Application stays `Synced`. See
`argocd/applications/grim-k8s.yaml`.

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
