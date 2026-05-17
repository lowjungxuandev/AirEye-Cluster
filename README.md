# grim-k8s

Single-cluster GitOps boilerplate for the `infra` namespace. ArgoCD reconciles
this repo from `main`; runtime secrets are synced from Vault with HashiCorp
Vault Secrets Operator.

- Architecture overview: [docs/architecture.md](docs/architecture.md)
- Deployment order: [docs/deployment-sequence.md](docs/deployment-sequence.md)
- Cloudflare proxy + Origin Cert TLS: [docs/cloudflare-proxy.md](docs/cloudflare-proxy.md)

## Stack

| Component | Purpose | Source |
|-----------|---------|--------|
| ingress-nginx | Cluster ingress, hostNetwork | Upstream baremetal manifest |
| postgres | DB for Keycloak and LiteLLM | `postgres:18-alpine` |
| redis | Cache backend for ArgoCD and LiteLLM | `redis:8-alpine` |
| keycloak | Identity provider, OIDC | `quay.io/keycloak/keycloak:26.6.1` |
| vault-secrets-operator | Sync Vault secrets into Kubernetes | Helm chart `vault-secrets-operator@1.4.0` |
| minio | S3-compatible object storage | `minio/minio` + standalone console |
| argocd | GitOps controller | Upstream manifest `v3.4.1` |
| grim-app | Application backend | `ghcr.io/lowjungxuandev/grim/backend` |
| litellm | Centralized AI API gateway | `ghcr.io/berriai/litellm:v1.83.14-stable.patch.3` |
| zealot | Mobile app (APK/IPA) distribution platform | `ghcr.io/tryzealot/zealot:nightly-2026-05-14` |

## Folder Structure

```text
.
├── argocd/                 # ArgoCD install, patches, ingress, and Applications
├── docs/                   # architecture and deployment notes
├── grim-app/               # backend Deployment, Service, Ingress
├── ingress-nginx/          # manually bootstrapped ingress controller
├── keycloak/               # Deployment, Service, Ingress, bootstrap Job
├── litellm/                # LiteLLM Deployment, config, DB init, Service, Ingress
├── minio/                  # StatefulSet, console, Services, Ingress
├── postgres/               # StatefulSet, Service, PVC, init ConfigMap
├── redis/                  # StatefulSet, Service, PVC, smoke test
├── vault-secrets-operator/ # VaultConnection, VaultAuth, VaultStaticSecret resources
├── zealot/                 # Zealot Deployment, ConfigMap, PVCs, DB init, Service, Ingress
├── scripts/                # local validation
├── namespace.yaml
└── kustomization.yaml      # ArgoCD root app entrypoint
```

## Bootstrap Order

```sh
# 1. Cluster ingress.
kubectl apply -k ingress-nginx

# 2. Install Cloudflare Origin Cert TLS Secrets.
# See docs/cloudflare-proxy.md.

# 3. Ensure Vault already contains the required secret keys below.

# 4. Apply workload manifests.
kubectl apply -k .

# 5. Bootstrap ArgoCD and the self-managed Application.
kubectl apply --server-side=true --force-conflicts -k argocd
kubectl apply -k argocd/applications
```

## Required Vault Keys

The existing Vault convention is KV-v2 mount `secret`, path `grim-k8s`.
Values below are synced into `server-secret`, `litellm-secret`, and ArgoCD
support secrets by VSO. Do not commit real values.

LiteLLM requires:

```text
LITELLM_MASTER_KEY          # must start with sk-
LITELLM_SALT_KEY            # persistent value; do not rotate automatically
DATABASE_URL                # postgresql://<user>:<password>@postgres.infra.svc.cluster.local:5432/litellm
REDIS_HOST                  # redis.infra.svc.cluster.local
REDIS_PORT                  # 6379
REDIS_PASSWORD
OPENAI_API_KEY
DEEPSEEK_API_KEY
OPENROUTER_API_KEY
NVIDIA_NIM_API_KEY
```

Zealot requires:

```text
ZEALOT_ADMIN_EMAIL          # bootstrap admin user email
ZEALOT_ADMIN_PASSWORD       # bootstrap admin user password
ZEALOT_SECRET_TOKEN         # Rails secret_key_base; generate once via `openssl rand -hex 64`, never rotate
```

Zealot reuses `POSTGRES_USER`, `POSTGRES_PASSWORD`, `OIDC_CLIENT_ID`, and
`OIDC_CLIENT_SECRET` from the existing platform keys.

LiteLLM SSO reuses the existing global Keycloak client values from
`OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`. VSO maps them into LiteLLM's
`GENERIC_CLIENT_ID` and `GENERIC_CLIENT_SECRET` keys and adds the Keycloak OIDC
endpoints.

The existing platform keys for Postgres, Redis, Keycloak, MinIO, ArgoCD, and
`grim-app-secret` are still required by their respective workloads.

## Sync Waves

```text
wave -1  Application/vault-secrets-operator
wave 0   VaultStaticSecret/server-secret, grim-app-secret, litellm-secret, zealot-secret
wave 0   infrastructure and services
wave 5   Job/litellm-postgres-init, Job/zealot-postgres-init
wave 10  Job/keycloak-bootstrap
wave 10  Deployment/grim-app
wave 10  Deployment/litellm
wave 10  Deployment/zealot + PVCs (zealot-uploads, zealot-backup)
```

## Validation

```sh
bash scripts/validate.sh
```

The script renders the root, `argocd`, and `argocd/applications`
entrypoints, then runs `yamllint` and `kubeconform` when installed.

## Hosts

| Host | Service |
|------|---------|
| `argocd.lowjungxuan.dpdns.org` | ArgoCD UI |
| `keycloak.lowjungxuan.dpdns.org` | Keycloak |
| `minio.lowjungxuan.dpdns.org` | MinIO console |
| `s3.lowjungxuan.dpdns.org` | MinIO S3 API |
| `api.lowjungxuan.dpdns.org` | grim-app backend |
| `litellm.lowjungxuan.dpdns.org` | LiteLLM UI/API |
| `zealot.lowjungxuan.dpdns.org` | Zealot mobile app distribution |

## LiteLLM Verification

```sh
kubectl -n infra get vaultstaticsecret litellm-secret
kubectl -n infra get secret litellm-secret
kubectl -n infra rollout status deploy/litellm
curl -I https://litellm.lowjungxuan.dpdns.org/ui
curl -s https://litellm.lowjungxuan.dpdns.org/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

The UI is available at `https://litellm.lowjungxuan.dpdns.org/ui`. The OpenAI
compatible API is available at
`https://litellm.lowjungxuan.dpdns.org/v1/chat/completions`.
SSO uses `https://litellm.lowjungxuan.dpdns.org/sso/callback`; fallback
username/password login remains available at `/fallback/login`.

The initial model aliases in `litellm/configmap.yaml` are editable defaults.
Update the provider model names there when you choose the exact OpenAI,
DeepSeek, OpenRouter, and NVIDIA NIM models to expose.

## Conventions

- All workload resources land in `infra`; ArgoCD itself lives in `argocd`.
- Real secret values never enter git.
- LiteLLM model aliases live in `litellm/configmap.yaml`; provider keys come
  only from Vault/VSO.
- LiteLLM does not use VSO rollout restarts because startup runs Prisma
  migrations; restart it manually after changing LiteLLM secrets.
- Root kustomize adds the common `app.kubernetes.io/part-of` and
  `app.kubernetes.io/managed-by` labels.
- Root kustomize adds control-plane tolerations for workloads.

## Upstream Notes

- MinIO open-source archived 2026-04-25. Docker images stopped publishing
  after `RELEASE.2025-09-07T16-13-09Z`; this repo pins that release.
- ingress-nginx plans to archive after KubeCon 2026; consider Gateway API
  migration in the future.
