# grim-k8s

Single-cluster GitOps boilerplate for the `infra` namespace.

## Stack

| Component       | Purpose                              | Source                                 |
|-----------------|--------------------------------------|----------------------------------------|
| ingress-nginx   | Cluster ingress (hostNetwork)        | Upstream baremetal manifest            |
| cert-manager    | Let's Encrypt TLS                    | Upstream + `ClusterIssuer`             |
| postgres        | DB for keycloak + vault              | `postgres:18-alpine`                   |
| redis           | Cache backend for ArgoCD             | `redis:8-alpine`                       |
| keycloak        | Identity provider (OIDC)             | `quay.io/keycloak/keycloak:26.6.1`     |
| vault           | Secrets backend (PostgreSQL storage) | Helm chart `hashicorp/vault@0.32.0`    |
| external-secrets| Sync secrets from Vault → k8s        | Operator (install separately)          |
| minio           | S3-compatible object storage         | `minio/minio` + standalone console     |
| argocd          | GitOps controller                    | Upstream manifest `v3.4.1`             |
| grim-app        | Application backend                  | `ghcr.io/lowjungxuandev/grim/backend`  |

## Bootstrap order

```sh
# 1. Cluster ingress + TLS issuer + ESO operator must be in place first.
kubectl apply -k ingress-nginx
kubectl apply -k cert-manager
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace

# 2. Stateful infra + ESO custom resources (postgres, redis, keycloak, minio, grim-app).
kubectl apply -k .

# 3. Vault (Helm chart inflated by kustomize) + bootstrap jobs.
kubectl kustomize --enable-helm vault | kubectl apply -f -

# 4. ArgoCD itself.
kubectl apply -k argocd

# 5. The self-managed Application that points back at this repo.
kubectl apply -k argocd/applications
```

After step 5, ArgoCD reconciles everything in this repo automatically.

## Conventions

- **Namespace**: All resources land in `infra` (set by root `kustomization.yaml`).
- **Common labels**: `app.kubernetes.io/part-of: grim-k8s`, `app.kubernetes.io/managed-by: argocd`.
- **Tolerations**: Applied at root level via kustomize patches (no inline tolerations).
- **Secrets**: Single source of truth is Vault `secret/grim-k8s` → synced to `server-secret` by ESO.

## Hosts

| Host                                      | Service           |
|-------------------------------------------|-------------------|
| `argocd.lowjungxuan.dpdns.org`            | ArgoCD UI         |
| `keycloak.lowjungxuan.dpdns.org`          | Keycloak          |
| `vault.lowjungxuan.dpdns.org`             | Vault UI          |
| `minio.lowjungxuan.dpdns.org`             | MinIO console     |
| `s3.lowjungxuan.dpdns.org`                | MinIO S3 API      |
| `api.lowjungxuan.dpdns.org`               | grim-app backend  |

## Health checks

```sh
kubectl get pods -A
kubectl get ingress,certificate,externalsecret,application -A
curl -vL https://argocd.lowjungxuan.dpdns.org/
```

## Notes on versions

- **MinIO open-source was archived on 2026-04-25.** Docker images stopped publishing after `RELEASE.2025-09-07T16-13-09Z`; this repo pins that release. Plan a migration (Chainguard image, build from source, or alternative S3-compatible backend) before relying on it long-term.
- **ingress-nginx** plans to archive after Kubecon 2026; consider Gateway API / `ingate` migration in the future.
- **ArgoCD v3.4** introduced an MS Teams Workflows breaking change — not applicable here (no Teams notifications configured).
- **cert-manager v1.19** bumped Go to fix DNS SAN validation CVEs; no API changes for our `ClusterIssuer`.
