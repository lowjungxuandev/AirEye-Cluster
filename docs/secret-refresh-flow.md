# Secret refresh flow

How a Vault edit reaches a running pod.

```
┌────────────────────┐
│ Vault UI / CLI     │  edit secret/grim-app-secret
└──────────┬─────────┘
           │
           ▼  every 5 min  (refreshInterval)
┌────────────────────┐
│ ExternalSecret     │  external-secrets/external-secrets.yaml
│ grim-app-secret    │
└──────────┬─────────┘
           │  ESO writes
           ▼
┌────────────────────┐
│ K8s Secret         │
│ grim-app-secret    │  same name, same namespace (infra)
└──────────┬─────────┘
           │  Reloader watches
           ▼
┌────────────────────┐
│ Deployment         │  has annotation:
│ grim-app           │    secret.reloader.stakater.com/reload: grim-app-secret
└──────────┬─────────┘
           │  rollout restart
           ▼
┌────────────────────┐
│ Pod (new revision) │  reads new envFrom values
└────────────────────┘
```

## Why each piece exists

- **`refreshInterval: 5m`** — bounds how stale Kubernetes can be vs. Vault.
- **`creationPolicy: Owner`** — ESO owns and overwrites the Secret. Manual
  edits to the K8s Secret are clobbered on next sync.
- **Reloader annotation** — `envFrom` env vars are baked into the pod at
  startup. Updating the Secret does **not** restart the pod automatically;
  Reloader does.

## Force a refresh manually

```sh
# 1. Force ESO to re-read Vault now (don't wait 5 min)
kubectl -n infra annotate externalsecret grim-app-secret \
  force-sync="$(date +%s)" --overwrite

# 2. Verify the K8s Secret was updated
kubectl -n infra get externalsecret grim-app-secret
kubectl -n infra get secret grim-app-secret -o jsonpath='{.metadata.resourceVersion}'

# 3. If Reloader didn't trigger, restart manually
kubectl -n infra rollout restart deployment grim-app
kubectl -n infra rollout status  deployment grim-app
```

## What does NOT trigger a restart

- Editing the K8s Secret directly — ESO will revert it within 5 min.
- Editing Vault but waiting for ESO — refresh happens, but pods only
  pick it up if Reloader sees the Secret change OR you run `rollout restart`.
- Annotation-only changes on the Secret — Reloader hashes data, not metadata.

## What if Reloader is missing the annotation?

Confirm the Deployment has:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "grim-app-secret"
```

Currently set on `grim-app/deployment.yaml`. No other workloads use
`grim-app-secret`, so this is the only Deployment that needs it.
