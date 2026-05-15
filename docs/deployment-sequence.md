# Deployment sequence

End-to-end ordering for bringing this repo up on a fresh cluster: what's
applied by hand, what ArgoCD picks up, and which sync waves it uses
afterwards. Read top-to-bottom on a first install; thereafter only the
**ArgoCD waves** section matters.

## At a glance

```
manual:  ingress-nginx → CF Origin Cert Secrets → root kustomize → vault helm → vault config → argocd → argocd apps
gitops:  ArgoCD reconciles root path "." on every commit, in sync-wave order
```

Steps 1–7 are run by an operator with cluster-admin credentials. Step 8
onwards is GitOps — ArgoCD is the only thing that touches the cluster.

## Manual bootstrap (one-time)

### 1. Cluster prereqs

Install ingress-nginx and the Cloudflare Origin Cert TLS Secrets before
anything else needs ingress or TLS:

```sh
kubectl apply -k ingress-nginx
```

Then follow [cloudflare-proxy.md](cloudflare-proxy.md) to create the 5
TLS Secrets (`grim-app-tls`, `keycloak-tls`, `vault-tls`, `minio-tls` in
`infra`; `argocd-tls` in `argocd`). ingress-nginx reads each ingress'
`tls.secretName` directly — no operator needed.

### 2. Pre-create bootstrap Secrets

Two Secrets are read by workloads or Jobs before Vault can write them:

```sh
kubectl -n infra create secret generic server-secret    --from-env-file=grim-k8s.env
kubectl -n infra create secret generic grim-app-secret  --from-env-file=grim-app-secret.env
```

VSO takes ownership later because every `VaultStaticSecret` sets
`destination.overwrite: true` (issue #5).

### 3. Apply the root manifests

```sh
kubectl apply -k .
```

This installs:

- `vault-secrets-operator/` CRs (`VaultConnection`, `VaultAuth`,
  `ServiceAccount`, the per-app `VaultStaticSecret` resources). The
  **VSO controller itself** is installed separately in step 7 by ArgoCD.
- `postgres`, `redis`, `keycloak`, `minio`, `grim-app`.

The `VaultStaticSecret` resources will sit in `SecretSynced=False` until
step 7 brings up the VSO controller and step 5 seeds Vault.

### 4. Bring up Vault

Vault is installed via Helm and is not in the root kustomization —
apply it separately:

```sh
kubectl kustomize --enable-helm vault | kubectl apply -f -
```

This installs:

- The Vault `StatefulSet` (Helm chart `0.32.0`).
- `vault-bootstrap` — one-shot Job that initialises + unseals Vault and
  writes `vault-bootstrap-secret` with the root token and unseal key.
- `vault-auto-unseal` — CronJob that re-unseals every minute after pod
  restarts.
- `vault-auth-config` — Job that wires Vault's Kubernetes auth role,
  OIDC auth method, `keycloak` role, and `grim-k8s-read` policy
  (issue #10).

Wait for `vault-bootstrap` to finish, then `vault-auth-config`:

```sh
kubectl -n infra wait --for=condition=complete job/vault-bootstrap     --timeout=300s
kubectl -n infra wait --for=condition=complete job/vault-auth-config   --timeout=180s
```

### 5. Seed Vault KV data (manual)

VSO can only sync what exists in Vault. Run the `vault kv put` commands
in [architecture.md § Vault config (manual)](architecture.md#vault-config-manual)
to populate `secret/grim-k8s` and `secret/grim-app-secret`.
`secret/grim-k8s` carries shared infrastructure values plus Sub2API runtime
settings. All Keycloak OIDC clients use `OIDC_CLIENT_ID=global` and share
`OIDC_CLIENT_SECRET` from `secret/grim-k8s`.

This step is deliberately not in YAML — see the GitOps note in
[secret-refresh-flow.md § Out of scope for kustomize](secret-refresh-flow.md#out-of-scope-for-kustomize).

### 6. Install ArgoCD

ArgoCD's `applicationsets.argoproj.io` CRD exceeds kubectl's client-side
apply annotation limit (issue #3). Use server-side apply:

```sh
kubectl apply --server-side=true --force-conflicts -k argocd
```

### 7. Create the self-managed Applications

```sh
kubectl apply -k argocd/applications
```

This creates two `Application`s:

- `vault-secrets-operator` (wave `-1`) — installs the VSO Helm chart
  into the `vault-secrets-operator` namespace. Must land before any
  `VaultStaticSecret` is reconciled.
- `grim-k8s` (default wave `0`) — self-managed, syncs `path: .` of this
  repo into the `infra` namespace.

Once both are `Synced`, the cluster is GitOps-managed.

### 8. Force the first refresh

The pre-created bootstrap Secrets from step 2 will get overwritten by
VSO on its first sync. Speed this up:

```sh
kubectl -n infra annotate vaultstaticsecret server-secret \
  vso.hashicorp.com/force-sync="$(date +%s)" --overwrite
kubectl -n infra annotate vaultstaticsecret grim-app-secret \
  vso.hashicorp.com/force-sync="$(date +%s)" --overwrite
```

VSO will then rollout-restart every workload listed in each
`VaultStaticSecret`'s `rolloutRestartTargets` (issue #5; flow in
[secret-refresh-flow.md](secret-refresh-flow.md)).

## ArgoCD waves (every subsequent sync)

ArgoCD applies resources in ascending wave order. Resources without an
explicit wave default to `0`.

| Wave | Resource | File | Why this wave |
|------|----------|------|---------------|
| `-1` | `Application/vault-secrets-operator` | `argocd/applications/vault-secrets-operator.yaml` | VSO CRDs must exist before any `VaultStaticSecret` reconciles |
| `0` | `VaultConnection/vault-connection` | `vault-secrets-operator/vault-connection.yaml` | Default wave — applied as soon as VSO CRDs are ready |
| `0` | `VaultAuth/vault-auth` | `vault-secrets-operator/vault-auth.yaml` | Default wave — same reason |
| `0` | `VaultStaticSecret/server-secret` | `vault-secrets-operator/server-secret.yaml` | Default wave — writes the shared infra and Sub2API runtime Secret |
| `0` | `VaultStaticSecret/grim-app-secret` | `vault-secrets-operator/grim-app-secret.yaml` | Default wave — writes the app Secret |
| `0` | `Deployment`s + `StatefulSet`s (postgres, redis, keycloak, minio) | their respective dirs | Default wave — start once their Secrets exist; K8s retries Pod startup if Secret is briefly missing |
| `10` | `Job/keycloak-bootstrap` | `keycloak/bootstrap-job.yaml` | Needs Keycloak running before it can register OIDC clients (issues #8, #9) |
| `10` | `Deployment/grim-app` | `grim-app/deployment.yaml` | Starts after the secrets and Keycloak clients are in place |
| `10` | `Deployment/sub2api` | `sub2api/deployment.yaml` | Starts after `server-secret` exists and the Keycloak OIDC client has been bootstrapped |

### Re-runnable Jobs

Both `keycloak-bootstrap` and `vault-auth-config` carry
`argocd.argoproj.io/sync-options: Force=true,Replace=true`. ArgoCD
recreates them on every sync instead of failing on the immutable
`Job.spec.template` (issue #1).

### Drift handling

The `grim-k8s` Application sets:

```yaml
ignoreDifferences:
  - group: ""
    kind: Secret
    jsonPointers: [/data]
    jqPathExpressions:
      - .metadata.annotations."app.kubernetes.io/managed-by"
      - .metadata.labels."app.kubernetes.io/managed-by"
```

VSO mutates `/data` on every refresh and the ArgoCD admission controller
re-stamps `managed-by` labels — without this, every refreshed Secret
would flap `OutOfSync`. See
[secret-refresh-flow.md § ArgoCD drift handling](secret-refresh-flow.md#argocd-drift-handling).

## Tear-down order

Reverse of bring-up. The order that matters in practice:

1. `kubectl delete -k argocd/applications` — stop the GitOps loop first.
2. `kubectl delete -k argocd` — remove ArgoCD itself.
3. `kubectl delete -k .` — workloads + VSO CRs.
4. `kubectl kustomize --enable-helm vault | kubectl delete -f -` — Vault.
5. Manual cleanup: `vault-bootstrap-secret`, the two pre-created
   bootstrap Secrets, namespaces.

## Related docs

- [architecture.md](architecture.md) — components, trust topology, manual Vault config.
- [secret-refresh-flow.md](secret-refresh-flow.md) — Vault → Pod refresh path.
- [issue.md](issue.md) — every issue cited by number above.
- [refactor-summary.md](refactor-summary.md) — what changed and why.
