# AirEye-Cluster

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
| aireye-app | Application backend (AirEye) | `ghcr.io/lowjungxuandev/aireye/backend` |
| litellm | Centralized AI API gateway | `ghcr.io/berriai/litellm:v1.83.14-stable.patch.3` |

## Folder Structure

```text
.
├── argocd/                 # ArgoCD install, patches, ingress, and Applications
├── docs/                   # architecture and deployment notes
├── aireye-app/               # backend Deployment, Service, Ingress
├── ingress-nginx/          # manually bootstrapped ingress controller
├── keycloak/               # Deployment, Service, Ingress, bootstrap Job
├── litellm/                # LiteLLM Deployment, config, DB init, Service, Ingress
├── minio/                  # StatefulSet, console, Services, Ingress
├── postgres/               # StatefulSet, Service, PVC, init ConfigMap
├── redis/                  # StatefulSet, Service, PVC, smoke test
├── vault-secrets-operator/ # VaultConnection, VaultAuth, VaultStaticSecret resources
├── scripts/                # local validation
├── namespace.yaml
└── kustomization.yaml      # ArgoCD root app entrypoint
```

## Bootstrap Order

```sh
# 1. Cluster ingress.
kubectl apply -k ingress-nginx

# 2. Install Cloudflare Origin Cert TLS Secrets (incl. vault-tls).
# See docs/cloudflare-proxy.md.

# 3. Pre-create the bootstrap secret with the Vault Postgres URL.
# ArgoCD's vault app cannot start without this key, since the
# Vault StatefulSet reads VAULT_PG_CONNECTION_URL from server-secret.
kubectl create namespace infra
kubectl create secret generic -n infra server-secret \
  --from-literal=VAULT_PG_CONNECTION_URL='postgresql://...'

# 4. Bootstrap ArgoCD and the self-managed Applications.
# ArgoCD will then deploy in sync-wave order:
#   wave -2  Application/vault          (Helm chart + bootstrap/auth-config Jobs + auto-unseal CronJob)
#   wave -1  Application/vault-secrets-operator
#   wave 0+  Application/aireye-cluster       (everything else)
kubectl apply --server-side=true --force-conflicts -k argocd
kubectl apply -k argocd/applications
```

`vault-bootstrap-secret` (Vault unseal key + root token) is created by the
`vault-bootstrap` Job on first sync and stays out of Git. The
`vault-auto-unseal` CronJob re-unseals Vault after pod restarts.

## Required Vault Keys

The existing Vault convention is KV-v2 mount `secret`, path `aireye-cluster`.
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

LiteLLM SSO reuses the existing global Keycloak client values from
`OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`. VSO maps them into LiteLLM's
`GENERIC_CLIENT_ID` and `GENERIC_CLIENT_SECRET` keys and adds the Keycloak OIDC
endpoints.

The existing platform keys for Postgres, Redis, Keycloak, MinIO, ArgoCD, and
`aireye-app-secret` are still required by their respective workloads.

## Sync Waves

```text
wave -2  Application/vault                (Helm + local bootstrap/auth/unseal)
wave -1  Application/vault-secrets-operator
wave  0  VaultStaticSecret/server-secret, aireye-app-secret, litellm-secret
wave  0  infrastructure and services
wave  5  Hook(Sync)/litellm-postgres-init
wave 10  Deployment/aireye-app
wave 10  Deployment/litellm
PostSync Hook/keycloak-bootstrap, Hook/redis-smoke-test,
         Hook/vault-bootstrap (wave 0), Hook/vault-auth-config (wave 1)
```

Bootstrap-style Jobs now run as ArgoCD Hooks (`PostSync` or `Sync`) with
`hook-delete-policy: BeforeHookCreation` instead of tracked resources with
`Replace=true`. This eliminates the OutOfSync churn that previously fired
on every reconcile.

## Validation

```sh
bash scripts/validate.sh
```

The script renders the root, `argocd`, and `argocd/applications`
entrypoints, then runs `yamllint` and `kubeconform` when installed.

Before or after a cluster sync, check ArgoCD, Vault Secrets Operator, and hook
Job health:

```sh
bash scripts/check-cluster-sync.sh
```

## Hosts

| Host | Service |
|------|---------|
| `argocd.lowjungxuan.dpdns.org` | ArgoCD UI |
| `keycloak.lowjungxuan.dpdns.org` | Keycloak |
| `minio.lowjungxuan.dpdns.org` | MinIO console |
| `s3.lowjungxuan.dpdns.org` | MinIO S3 API |
| `api.lowjungxuan.dpdns.org` | aireye-app backend |
| `litellm.lowjungxuan.dpdns.org` | LiteLLM UI/API |

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

## Operations Notes

- **Keycloak `master` realm Access Token Lifespan**: set to at least 5
  minutes. Sub-minute lifespans cause `argocd-server` to log
  `oidc: token is expired` ~10×/second from browser Watch streams. Sync
  itself is unaffected (the controller uses a Kubernetes SA token, not OIDC).
- **`aireye-app` uses `:latest`** with `imagePullPolicy: Always`. Pods do not
  auto-restart on a new push; do `kubectl -n infra rollout restart deploy/aireye-app`
  to pick up a new image digest.
