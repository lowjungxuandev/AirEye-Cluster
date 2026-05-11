# grim-k8s

Single-cluster GitOps boilerplate for the `infra` namespace. ArgoCD reconciles
this repo from `main`; secrets land in Kubernetes via the HashiCorp Vault
Secrets Operator (VSO) pulling from Vault.

- Architecture overview → [docs/architecture.md](docs/architecture.md)
- Vault → Secret → Pod restart flow → [docs/secret-refresh-flow.md](docs/secret-refresh-flow.md)
- Cloudflare proxy + Origin Cert TLS → [docs/cloudflare-proxy.md](docs/cloudflare-proxy.md)
- Issues, diagnostics, and fixes → [docs/issue.md](docs/issue.md)
- What changed in the last cleanup pass → [docs/refactor-summary.md](docs/refactor-summary.md)

## Stack

| Component       | Purpose                              | Source                                 |
|-----------------|--------------------------------------|----------------------------------------|
| ingress-nginx   | Cluster ingress (hostNetwork)        | Upstream baremetal manifest            |
| postgres        | DB for keycloak + vault              | `postgres:18-alpine`                   |
| redis           | Cache backend for ArgoCD             | `redis:8-alpine`                       |
| keycloak        | Identity provider (OIDC)             | `quay.io/keycloak/keycloak:26.6.1`     |
| vault           | Secrets backend (PostgreSQL storage) | Helm chart `hashicorp/vault@0.32.0`    |
| vault-secrets-operator | Sync secrets from Vault → k8s | Helm chart `hashicorp/vault-secrets-operator@0.10.0` |
| minio           | S3-compatible object storage         | `minio/minio` + standalone console     |
| argocd          | GitOps controller                    | Upstream manifest `v3.4.1`             |
| grim-app        | Application backend                  | `ghcr.io/lowjungxuandev/grim/backend`  |

## Folder structure

```
.
├── README.md
├── kustomization.yaml         # ArgoCD entrypoint (path: .)
├── namespace.yaml             # the infra namespace
│
├── argocd/                       # ArgoCD itself (bootstrapped manually)
│   ├── applications/             # self-managed Application + VSO Application
│   ├── patches/                  # config + tolerations
│   ├── vault-secrets.yaml        # VaultConnection/VaultAuth + VSS for argocd ns
│   └── ingress.yaml
├── vault-secrets-operator/       # VaultConnection/VaultAuth + VSS for infra ns
├── ingress-nginx/                # bootstrapped manually
├── keycloak/                     # Deployment + bootstrap-job (registers OIDC clients)
├── minio/                        # StatefulSet + console + ingress
├── postgres/                     # StatefulSet + init-configmap
├── redis/                        # StatefulSet + smoke-test job
├── vault/                        # Helm chart + bootstrap/seed/oidc/auto-unseal jobs
├── grim-app/                     # the application
│
├── docs/                      # architecture, secret flow, troubleshooting
└── scripts/                   # validate.sh, troubleshoot-secrets.sh
```

## Bootstrap order

ArgoCD takes over after step 5. Steps 1–4 are one-time manual setup.

```sh
# 1. Cluster ingress must be in place first.
kubectl apply -k ingress-nginx

# 1b. Install the Cloudflare Origin Cert as TLS Secrets — see
#     docs/cloudflare-proxy.md for the full flow.

# 2a. Pre-create secrets so postgres + vault can boot.
#     VSO takes ownership (destination.create: true) once Vault is seeded.
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -

kubectl -n infra create secret generic server-secret \
  --from-literal=POSTGRES_USER=<your-value> \
  --from-literal=POSTGRES_PASSWORD=<your-value> \
  --from-literal=POSTGRES_DB=<your-value> \
  --from-literal=KEYCLOAK_DB_PASSWORD=<your-value> \
  --from-literal=VAULT_DB_PASSWORD=<your-value> \
  --from-literal=VAULT_PG_CONNECTION_URL='postgres://<vault-user>:<vault-pass>@postgres.infra.svc.cluster.local:5432/vault?sslmode=disable' \
  --from-literal=KC_DB=postgres \
  --from-literal=KC_DB_URL='jdbc:postgresql://postgres.infra.svc.cluster.local:5432/keycloak' \
  --from-literal=KC_DB_USERNAME=<your-value> \
  --from-literal=KEYCLOAK_ADMIN=<your-value> \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD=<your-value> \
  --from-literal=KEYCLOAK_USER_USERNAME=<your-value> \
  --from-literal=KEYCLOAK_USER_PASSWORD=<your-value> \
  --from-literal=KEYCLOAK_USER_EMAIL=<your-value> \
  --from-literal=OIDC_CLIENT_ID=vault \
  --from-literal=OIDC_CLIENT_SECRET=<your-value> \
  --from-literal=REDIS_PASSWORD=<your-value> \
  --from-literal=ARGOCD_OIDC_CLIENT_ID=argocd \
  --from-literal=ARGOCD_OIDC_CLIENT_SECRET=<your-value> \
  --from-literal=MINIO_ROOT_USER=<your-value> \
  --from-literal=MINIO_ROOT_PASSWORD=<your-value> \
  --from-literal=MINIO_OIDC_CLIENT_ID=minio \
  --from-literal=MINIO_OIDC_CLIENT_SECRET=<your-value> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n infra create secret generic grim-app-secret \
  --from-literal=DEEPSEEK_API_KEY=<your-value> \
  --from-literal=DEEPSEEK_BASE_URL=<your-value> \
  --from-literal=DEEPSEEK_EXTRACT_MODEL=<your-value> \
  --from-literal=DEEPSEEK_FINAL_MODEL=<your-value> \
  --from-literal=DEV_FORCE_KILL_PORT=false \
  --from-literal=FIREBASE_DATABASE_URL=<your-value> \
  --from-literal=FIREBASE_PROJECT_ID=<your-value> \
  --from-literal=GOOGLE_APPLICATION_CREDENTIALS=<base64-encoded-service-account-json> \
  --from-literal=GRIM_FCM_TOPIC=<your-value> \
  --from-literal=NVIDIA_API_KEY=<your-value> \
  --from-literal=NVIDIA_BASE_URL=<your-value> \
  --from-literal=NVIDIA_EXTRACT_MODEL=<your-value> \
  --from-literal=NVIDIA_FINAL_MODEL=<your-value> \
  --from-literal=OPENAI_API_KEY=<your-value> \
  --from-literal=OPENAI_BASE_URL=https://api.openai.com/v1 \
  --from-literal=OPENAI_EXTRACT_MODEL=<your-value> \
  --from-literal=OPENAI_FINAL_MODEL=<your-value> \
  --from-literal=OPENROUTER_API_KEY=<your-value> \
  --from-literal=OPENROUTER_BASE_URL=https://openrouter.ai/api/v1 \
  --from-literal=OPENROUTER_EXTRACT_MODEL=<your-value> \
  --from-literal=OPENROUTER_FINAL_MODEL=<your-value> \
  --from-literal=PORT=3001 \
  --from-literal=S3_ACCESS_KEY_ID=<your-value> \
  --from-literal=S3_BUCKET_DEVELOPMENT=<your-value> \
  --from-literal=S3_BUCKET_PRODUCTION=<your-value> \
  --from-literal=S3_BUCKET_TESTING=<your-value> \
  --from-literal=S3_ENDPOINT=<your-value> \
  --from-literal=S3_PRESIGN_TTL_SECONDS=604800 \
  --from-literal=S3_REGION=us-east-1 \
  --from-literal=S3_SECRET_ACCESS_KEY=<your-value> \
  --dry-run=client -o yaml | kubectl apply -f -

# 2b. Stateful infra + VSO custom resources (VaultConnection, VaultAuth,
#     VaultStaticSecrets). The VSO operator itself is installed by an
#     ArgoCD Application created in step 5.
kubectl apply -k .

# 3. Vault (Helm chart inflated by kustomize) + bootstrap jobs.
#    vault-bootstrap initialises and unseals vault.
#    vault-auto-unseal CronJob keeps it unsealed every minute.
kubectl kustomize --enable-helm vault | kubectl apply -f -

# 4. Configure Vault MANUALLY (kv put, policies, auth methods).
#    Full command list in docs/architecture.md "Vault config (manual)".

# 5. ArgoCD itself.
kubectl apply -k argocd

# 6. Self-managed Application + the standalone VSO Application
#    (sync-wave: -1 so VSO starts before the rest).
kubectl apply -k argocd/applications
```

After step 5, ArgoCD reconciles every resource listed in the root
`kustomization.yaml`.

## Sync waves

```
wave -1  Application/vault-secrets-operator  (VSO must run before VSS reconcile)
wave 0   VaultStaticSecret/grim-app-secret   (Secret must exist before pod)
wave 0   everything else (default)
wave 10  Job/keycloak-bootstrap              (Keycloak must be running)
wave 10  Deployment/grim-app                 (consumes grim-app-secret)
```

## Validation

Before pushing changes, render every entrypoint locally:

```sh
bash scripts/validate.sh
```

The script runs `kubectl kustomize --enable-helm` on each entrypoint and, if
installed, `yamllint` and `kubeconform`.

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
kubectl get ingress,certificate,vaultstaticsecret,application -A
curl -vL https://argocd.lowjungxuan.dpdns.org/
```

Or:

```sh
bash scripts/troubleshoot-secrets.sh
```

## Manual secret refresh

When you edit a value in the Vault UI, VSO re-reads it within 30 s and
triggers a rolling restart of every workload listed in the
VaultStaticSecret's `rolloutRestartTargets`. To force the chain
immediately:

```sh
# 1. Force VSO to resync from Vault now
kubectl -n infra annotate vaultstaticsecret grim-app-secret \
  vso.hashicorp.com/force-sync="$(date +%s)" --overwrite

# 2. (Only if a workload isn't in rolloutRestartTargets)
kubectl -n infra rollout restart deployment grim-app
kubectl -n infra rollout status  deployment grim-app
```

Full flow with diagrams: [docs/secret-refresh-flow.md](docs/secret-refresh-flow.md).

## Conventions

- **Namespace**: All workload resources land in `infra` (set by root `kustomization.yaml`); ArgoCD itself lives in `argocd`.
- **Common labels**: `app.kubernetes.io/part-of: grim-k8s`, `app.kubernetes.io/managed-by: argocd` — applied at root level via kustomize `labels` (with `includeSelectors: false`).
- **Tolerations**: Applied at root level via kustomize patches (no inline tolerations).
- **Secrets**: Single source of truth is Vault (`secret/grim-k8s`, `secret/grim-app-secret`). Real values never enter git.

## Upstream notes

- **MinIO open-source archived 2026-04-25.** Docker images stopped publishing after `RELEASE.2025-09-07T16-13-09Z`; this repo pins that release. Plan a migration (Chainguard image, build from source, or alternative S3-compatible backend) before relying on it long-term.
- **ingress-nginx** plans to archive after Kubecon 2026; consider Gateway API / `ingate` migration in the future.
- **ArgoCD v3.4** introduced an MS Teams Workflows breaking change — not applicable here (no Teams notifications configured).
