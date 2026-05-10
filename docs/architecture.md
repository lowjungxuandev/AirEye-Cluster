# Architecture

Single-cluster GitOps stack. All workloads live in the `infra` namespace except
ArgoCD itself, which lives in `argocd`.

## Components

| Layer        | Component         | Role                                                  |
|--------------|-------------------|-------------------------------------------------------|
| Network      | ingress-nginx     | Cluster ingress (hostNetwork)                         |
| TLS          | cert-manager      | Let's Encrypt issuer (HTTP-01)                        |
| Data         | postgres          | DB for keycloak + vault                               |
| Cache        | redis             | ArgoCD session/state cache                            |
| Identity     | keycloak          | OIDC IdP for ArgoCD, MinIO, Vault UI                  |
| Secrets      | vault             | KV-v2 backend (`secret/grim-k8s`, `secret/grim-app-secret`) |
| Sync         | external-secrets  | Pulls Vault secrets into Kubernetes Secrets           |
| Storage      | minio             | S3-compatible object store + standalone console       |
| Reload       | reloader          | Restarts pods when their consumed Secret changes      |
| GitOps       | argocd            | Reconciles this repo into the cluster                 |
| App          | grim-app          | Backend service (`api.lowjungxuan.dpdns.org`)         |

## Trust topology

```
              Keycloak (OIDC IdP)
              /      |      \
           argocd  minio   vault-ui
              \      |      /
               server-secret (K8s Secret)
                     |
              ExternalSecret
                     |
                Vault: secret/grim-k8s
```

`grim-app` consumes `grim-app-secret` (a separate Vault path) via `envFrom`.

## Secret flow

See [secret-refresh-flow.md](secret-refresh-flow.md). One-line summary:

```
Vault KV  →  ESO (refreshInterval: 5m)  →  K8s Secret  →  Reloader  →  Pod restart
```

## Bootstrap order

Resources marked **manual** must be applied before ArgoCD takes over.

1. **manual** — `ingress-nginx`, `cert-manager`, ESO operator (Helm)
2. **manual** — pre-create `server-secret` and `grim-app-secret` (placeholder values)
3. **manual** — `kubectl apply -k .` (postgres, redis, keycloak, minio, reloader, grim-app, ESO CRs, ClusterIssuer)
4. **manual** — `kubectl kustomize --enable-helm vault | kubectl apply -f -`
   - `vault-bootstrap` initialises + unseals Vault
   - `vault-auto-unseal` CronJob keeps it unsealed
   - `vault-seed-secrets` writes `secret/grim-k8s` (always) and `secret/grim-app-secret` (first run only)
   - `vault-keycloak-oidc` wires the OIDC auth method
5. **manual** — `kubectl apply -k argocd`
6. **manual** — `kubectl apply -k argocd/applications` — self-managed Application
7. **GitOps** — ArgoCD reconciles everything in step 3 from then on.

## Sync waves

ArgoCD applies resources in ascending wave order. The repo uses two waves:

| Wave | Resource                                | Why                                         |
|------|------------------------------------------|---------------------------------------------|
| 0    | `ExternalSecret/grim-app-secret`         | K8s Secret must exist before consumer pods  |
| 10   | `Job/keycloak-bootstrap`                 | Needs Keycloak running to register clients  |
| 10   | `Deployment/grim-app`                    | Consumes `grim-app-secret` via envFrom      |

Resources without a wave default to wave 0.
